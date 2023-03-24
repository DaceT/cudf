/*
 * Copyright (c) 2023, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include <nvtext/minhash.hpp>

#include <cudf/column/column.hpp>
#include <cudf/column/column_device_view.cuh>
#include <cudf/column/column_factories.hpp>
#include <cudf/detail/hashing.hpp>
#include <cudf/detail/null_mask.hpp>
#include <cudf/detail/nvtx/ranges.hpp>
#include <cudf/detail/sequence.hpp>
#include <cudf/detail/utilities/cuda.cuh>
#include <cudf/detail/utilities/device_operators.cuh>
#include <cudf/detail/utilities/hash_functions.cuh>
#include <cudf/strings/string_view.cuh>
#include <cudf/utilities/default_stream.hpp>
#include <cudf/utilities/error.hpp>

#include <rmm/cuda_stream_view.hpp>
#include <rmm/exec_policy.hpp>

#include <thrust/iterator/counting_iterator.h>
#include <thrust/transform.h>

#include <cub/warp/warp_reduce.cuh>

#include <limits>

namespace nvtext {
namespace detail {
namespace {

__global__ void minhash_fn(cudf::column_device_view d_strings,
                           cudf::device_span<cudf::hash_value_type const> seeds,
                           cudf::size_type width,
                           cudf::hash_value_type* d_hashes)
{
  cudf::size_type const idx = static_cast<cudf::size_type>(threadIdx.x + blockIdx.x * blockDim.x);
  using warp_reduce         = cub::WarpReduce<cudf::hash_value_type>;
  __shared__ typename warp_reduce::TempStorage temp_storage;

  if (idx >= (d_strings.size() * cudf::detail::warp_size)) { return; }

  auto const str_idx  = idx / cudf::detail::warp_size;
  auto const lane_idx = idx % cudf::detail::warp_size;

  if (d_strings.is_null(str_idx)) { return; }
  auto const d_str = d_strings.element<cudf::string_view>(str_idx);

  for (auto seed_idx = 0; seed_idx < static_cast<cudf::size_type>(seeds.size()); ++seed_idx) {
    auto const output_idx = str_idx * seeds.size() + seed_idx;

    auto const seed   = seeds[seed_idx];
    auto const hasher = cudf::detail::MurmurHash3_32<cudf::string_view>{seed};

    auto const begin = d_str.begin() + lane_idx;
    auto const end   = (d_str.length() <= width) ? d_str.end() : d_str.end() - (width - 1);

    auto mh = d_str.empty() ? 0 : std::numeric_limits<cudf::hash_value_type>::max();
    for (auto itr = begin; itr < end; itr += cudf::detail::warp_size) {
      auto const offset = itr.byte_offset();
      auto const ss =
        cudf::string_view(d_str.data() + offset, (itr + width).byte_offset() - offset);

      auto const hvalue = hasher(ss);
      // cudf::detail::hash_combine(seed, hasher(ss)); <-- matches cudf::hash() result

      mh = cudf::detail::min(hvalue, mh);
    }

    auto const mhash =
      warp_reduce(temp_storage).Reduce(mh, thrust::minimum<cudf::hash_value_type>{});
    if (lane_idx == 0) { d_hashes[output_idx] = mhash; }
  }
}

}  // namespace

std::unique_ptr<cudf::column> minhash(cudf::strings_column_view const& input,
                                      cudf::device_span<cudf::hash_value_type const> seeds,
                                      cudf::size_type width,
                                      rmm::cuda_stream_view stream,
                                      rmm::mr::device_memory_resource* mr)
{
  CUDF_EXPECTS(width > 1, "Parameter width should be an integer value of 2 or greater");

  auto output_type = cudf::data_type{cudf::type_to_id<cudf::hash_value_type>()};
  if (input.is_empty()) { return cudf::make_empty_column(output_type); }

  auto const d_strings = cudf::column_device_view::create(input.parent(), stream);

  auto hashes   = cudf::make_numeric_column(output_type,
                                          input.size() * static_cast<cudf::size_type>(seeds.size()),
                                          cudf::mask_state::UNALLOCATED,
                                          stream,
                                          mr);
  auto d_hashes = hashes->mutable_view().data<cudf::hash_value_type>();

  constexpr int block_size = 256;
  cudf::detail::grid_1d grid{input.size() * cudf::detail::warp_size, block_size};
  minhash_fn<<<grid.num_blocks, grid.num_threads_per_block, 0, stream.value()>>>(
    *d_strings, seeds, width, d_hashes);

  if (seeds.size() == 1) {
    hashes->set_null_mask(cudf::detail::copy_bitmask(input.parent(), stream, mr),
                          input.null_count());
    return hashes;
  }
  hashes->set_null_count(0);

  auto offsets = cudf::detail::sequence(
    input.size() + 1,
    cudf::numeric_scalar<cudf::size_type>(0),
    cudf::numeric_scalar<cudf::size_type>(static_cast<cudf::size_type>(seeds.size())),
    stream,
    mr);
  return make_lists_column(input.size(),
                           std::move(offsets),
                           std::move(hashes),
                           input.null_count(),
                           cudf::detail::copy_bitmask(input.parent(), stream, mr),
                           stream,
                           mr);
}

}  // namespace detail

std::unique_ptr<cudf::column> minhash(cudf::strings_column_view const& input,
                                      cudf::numeric_scalar<cudf::hash_value_type> seed,
                                      cudf::size_type width,
                                      rmm::mr::device_memory_resource* mr)
{
  CUDF_FUNC_RANGE();
  auto seeds = cudf::device_span<cudf::hash_value_type const>{seed.data(), 1};
  return detail::minhash(input, seeds, width, cudf::get_default_stream(), mr);
}

std::unique_ptr<cudf::column> minhash(cudf::strings_column_view const& input,
                                      cudf::device_span<cudf::hash_value_type const> seeds,
                                      cudf::size_type width,
                                      rmm::mr::device_memory_resource* mr)
{
  CUDF_FUNC_RANGE();
  return detail::minhash(input, seeds, width, cudf::get_default_stream(), mr);
}

}  // namespace nvtext
