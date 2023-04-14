/*
 * Copyright (c) 2022-2023, NVIDIA CORPORATION.
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

#include <lists/utilities.hpp>

#include <cudf/column/column.hpp>
#include <cudf/column/column_factories.hpp>
#include <cudf/detail/concatenate.hpp>
#include <cudf/detail/copy.hpp>
#include <cudf/detail/sorting.hpp>
#include <cudf/detail/structs/utilities.hpp>
#include <cudf/detail/utilities/linked_column.hpp>
#include <cudf/detail/utilities/vector_factories.hpp>
#include <cudf/lists/lists_column_view.hpp>
#include <cudf/table/experimental/row_operators.cuh>
#include <cudf/table/table_view.hpp>
#include <cudf/utilities/type_checks.hpp>
#include <cudf/utilities/type_dispatcher.hpp>

#include <rmm/mr/device/per_device_resource.hpp>

#include <thrust/iterator/transform_iterator.h>

#include <random>

namespace cudf {
namespace experimental {

namespace {

/**
 * @brief Removes the offsets of struct column's children
 *
 * @param c The column whose children are to be un-sliced
 * @return Children of `c` with offsets removed
 */
std::vector<column_view> unslice_children(column_view const& c)
{
  if (c.type().id() == type_id::STRUCT) {
    auto child_it = thrust::make_transform_iterator(c.child_begin(), [](auto const& child) {
      return column_view(
        child.type(),
        child.offset() + child.size(),  // This is hacky, we don't know the actual unsliced size but
                                        // it is at least offset + size
        child.head(),
        child.null_mask(),
        child.null_count(),
        0,
        unslice_children(child));
    });
    return {child_it, child_it + c.num_children()};
  }
  return {c.child_begin(), c.child_end()};
};

/**
 * @brief Removes the child column offsets of struct columns in a table.
 *
 * Given a table, this replaces any struct columns with similar struct columns that have their
 * offsets removed from their children. Structs that are children of list columns are not affected.
 *
 */
table_view remove_struct_child_offsets(table_view table)
{
  std::vector<column_view> cols;
  cols.reserve(table.num_columns());
  std::transform(table.begin(), table.end(), std::back_inserter(cols), [&](column_view const& c) {
    return column_view(c.type(),
                       c.size(),
                       c.head<uint8_t>(),
                       c.null_mask(),
                       c.null_count(),
                       c.offset(),
                       unslice_children(c));
  });
  return table_view(cols);
}

/**
 * @brief Decompose all struct columns in a table
 *
 * If a structs column is a tree with N leaves, then this function decomposes the tree into
 * N "linear trees" (branch factor == 1) and prunes common parents. Also returns a vector of
 * per-column `depth`s.
 *
 * A `depth` value is the number of nested levels as parent of the column in the original,
 * non-decomposed table, which are pruned during decomposition.
 *
 * Special handling is needed in the cases of structs column having lists as its first child. In
 * such situations, the function decomposes the tree of N leaves into N+1 linear trees in which the
 * second tree was generated by extracting out leaf of the first tree. This is to make sure there is
 * no structs column having child lists column in the output. Note that structs with lists children
 * in subsequent positions do not require any special treatment because the struct parent will be
 * pruned for all subsequent children.
 *
 * For example, if the original table has a column `Struct<Struct<int, float>, decimal>`,
 *
 *      S1
 *     / \
 *    S2  d
 *   / \
 *  i   f
 *
 * then after decomposition, we get three columns:
 * `Struct<Struct<int>>`, `float`, and `decimal`.
 *
 *  0   2   1  <- depths
 *  S1
 *  |
 *  S2      d
 *  |
 *  i   f
 *
 * The depth of the first column is 0 because it contains all its parent levels, while the depth
 * of the second column is 2 because two of its parent struct levels were pruned.
 *
 * Similarly, a struct column of type `Struct<int, Struct<float, decimal>>` is decomposed as follows
 *
 *     S1
 *    / \
 *   i   S2
 *      / \
 *     f   d
 *
 *  0   1   2  <- depths
 *  S1  S2  d
 *  |   |
 *  i   f
 *
 * In the case of structs column with a lists column as its first child such as
 * `Struct<List<int>, float>`, after decomposition we get three columns `Struct<>`,
 * `List<int>`, and `float`.
 *
 * When list columns are present, depending on the input flag `decompose_lists`, the decomposition
 * can be performed similarly to pure structs but list parent columns are NOT pruned. For example,
 * if the original table has a column `List<Struct<int, float>>`,
 *
 *    L
 *    |
 *    S
 *   / \
 *  i   f
 *
 * after decomposition, we get two columns
 *
 *  L   L
 *  |   |
 *  S   f
 *  |
 *  i
 *
 * The list parents are still needed to define the range of elements in the leaf that belong to the
 * same row.
 *
 * @param table The table whose struct columns to decompose.
 * @param decompose_lists Whether to decompose lists columns or output them unchanged
 * @param column_order The per-column order if using output with lexicographic comparison
 * @param null_precedence The per-column null precedence
 * @return A tuple containing a table with all struct columns decomposed, new corresponding column
 *         orders and null precedences and depths of the linearized branches
 */
auto decompose_structs(table_view table,
                       bool decompose_lists,
                       host_span<order const> column_order         = {},
                       host_span<null_order const> null_precedence = {})
{
  auto linked_columns = detail::table_to_linked_columns(table);

  std::vector<column_view> verticalized_columns;
  std::vector<order> new_column_order;
  std::vector<null_order> new_null_precedence;
  std::vector<int> verticalized_col_depths;
  for (size_t col_idx = 0; col_idx < linked_columns.size(); ++col_idx) {
    detail::linked_column_view const* col = linked_columns[col_idx].get();
    if (is_nested(col->type())) {
      // convert and insert
      std::vector<std::vector<detail::linked_column_view const*>> flattened;
      std::function<void(
        detail::linked_column_view const*, std::vector<detail::linked_column_view const*>*, int)>
        recursive_child = [&](detail::linked_column_view const* c,
                              std::vector<detail::linked_column_view const*>* branch,
                              int depth) {
          branch->push_back(c);
          if (decompose_lists && c->type().id() == type_id::LIST) {
            recursive_child(
              c->children[lists_column_view::child_column_index].get(), branch, depth + 1);
          } else if (c->type().id() == type_id::STRUCT) {
            for (size_t child_idx = 0; child_idx < c->children.size(); ++child_idx) {
              // When child_idx == 0, we also cut off the current branch if its first child is a
              // lists column.
              // In such cases, the last column of the current branch will be `Struct<List,...>` and
              // it will be modified to empty struct type `Struct<>` later on.
              if (child_idx > 0 || c->children[0]->type().id() == type_id::LIST) {
                verticalized_col_depths.push_back(depth + 1);
                branch = &flattened.emplace_back();
              }
              recursive_child(c->children[child_idx].get(), branch, depth + 1);
            }
          }
        };
      auto& branch = flattened.emplace_back();
      verticalized_col_depths.push_back(0);
      recursive_child(col, &branch, 0);

      for (auto const& branch : flattened) {
        column_view temp_col = *branch.back();

        // Change `Struct<List,...>` into empty struct type `Struct<>`.
        if (temp_col.type().id() == type_id::STRUCT &&
            (temp_col.num_children() > 0 && temp_col.child(0).type().id() == type_id::LIST)) {
          temp_col = column_view(temp_col.type(),
                                 temp_col.size(),
                                 temp_col.head(),
                                 temp_col.null_mask(),
                                 temp_col.null_count(),
                                 temp_col.offset(),
                                 {});
        }

        for (auto it = branch.crbegin() + 1; it < branch.crend(); ++it) {
          auto const& prev_col = *(*it);
          auto children =
            (prev_col.type().id() == type_id::LIST)
              ? std::vector<column_view>{*prev_col
                                            .children[lists_column_view::offsets_column_index],
                                         temp_col}
              : std::vector<column_view>{temp_col};
          temp_col = column_view(prev_col.type(),
                                 prev_col.size(),
                                 nullptr,
                                 prev_col.null_mask(),
                                 prev_col.null_count(),
                                 prev_col.offset(),
                                 std::move(children));
        }
        // Traverse upward and include any list columns in the ancestors
        for (detail::linked_column_view* parent = branch.front()->parent; parent;
             parent                             = parent->parent) {
          if (parent->type().id() == type_id::LIST) {
            // Include this parent
            temp_col = column_view(
              parent->type(),
              parent->size(),
              nullptr,  // list has no data of its own
              nullptr,  // If we're going through this then nullmask is already in another branch
              0,
              parent->offset(),
              {*parent->children[lists_column_view::offsets_column_index], temp_col});
          } else if (parent->type().id() == type_id::STRUCT) {
            // Replace offset with parent's offset
            temp_col = column_view(temp_col.type(),
                                   parent->size(),
                                   temp_col.head(),
                                   temp_col.null_mask(),
                                   temp_col.null_count(),
                                   parent->offset(),
                                   {temp_col.child_begin(), temp_col.child_end()});
          }
        }
        verticalized_columns.push_back(temp_col);
      }
      if (not column_order.empty()) {
        new_column_order.insert(new_column_order.end(), flattened.size(), column_order[col_idx]);
      }
      if (not null_precedence.empty()) {
        new_null_precedence.insert(
          new_null_precedence.end(), flattened.size(), null_precedence[col_idx]);
      }
    } else {
      verticalized_columns.push_back(*col);
      verticalized_col_depths.push_back(0);
      if (not column_order.empty()) { new_column_order.push_back(column_order[col_idx]); }
      if (not null_precedence.empty()) { new_null_precedence.push_back(null_precedence[col_idx]); }
    }
  }
  return std::make_tuple(table_view(verticalized_columns),
                         std::move(new_column_order),
                         std::move(new_null_precedence),
                         std::move(verticalized_col_depths));
}

/*
 * This helper function generates dremel data for any list-type columns in a
 * table. This data is necessary for lexicographic comparisons.
 */
auto list_lex_preprocess(table_view const& table, rmm::cuda_stream_view stream)
{
  std::vector<detail::dremel_data> dremel_data;
  std::vector<detail::dremel_device_view> dremel_device_views;
  for (auto const& col : table) {
    if (col.type().id() == type_id::LIST) {
      dremel_data.push_back(detail::get_comparator_data(col, {}, false, stream));
      dremel_device_views.push_back(dremel_data.back());
    }
  }
  auto d_dremel_device_views = detail::make_device_uvector_sync(
    dremel_device_views, stream, rmm::mr::get_current_device_resource());
  return std::make_tuple(std::move(dremel_data), std::move(d_dremel_device_views));
}

using column_checker_fn_t = std::function<void(column_view const&)>;

/**
 * @brief Check a table for compatibility with lexicographic comparison
 *
 * Checks whether a given table contains columns of non-relationally comparable types.
 */
void check_lex_compatibility(table_view const& input)
{
  // Basically check if there's any LIST of STRUCT or STRUCT of LIST hiding anywhere in the table
  column_checker_fn_t check_column = [&](column_view const& c) {
    if (c.type().id() == type_id::LIST) {
      auto const& list_col = lists_column_view(c);
      CUDF_EXPECTS(list_col.child().type().id() != type_id::STRUCT,
                   "Cannot lexicographic compare a table with a LIST of STRUCT column");
      check_column(list_col.child());
    } else if (c.type().id() == type_id::STRUCT) {
      for (auto child = c.child_begin(); child < c.child_end(); ++child) {
        CUDF_EXPECTS(child->type().id() != type_id::LIST,
                     "Cannot lexicographic compare a table with a STRUCT of LIST column");
        check_column(*child);
      }
    }
    if (not is_nested(c.type())) {
      CUDF_EXPECTS(is_relationally_comparable(c.type()),
                   "Cannot lexicographic compare a table with a column of type " +
                     cudf::type_to_name(c.type()));
    }
  };
  for (column_view const& c : input) {
    check_column(c);
  }
}

/**
 * @brief Check a table for compatibility with equality comparison
 *
 * Checks whether a given table contains columns of non-equality comparable types.
 */
void check_eq_compatibility(table_view const& input)
{
  column_checker_fn_t check_column = [&](column_view const& c) {
    if (not is_nested(c.type())) {
      CUDF_EXPECTS(is_equality_comparable(c.type()),
                   "Cannot compare equality for a table with a column of type " +
                     cudf::type_to_name(c.type()));
    }
    for (auto child = c.child_begin(); child < c.child_end(); ++child) {
      check_column(*child);
    }
  };
  for (column_view const& c : input) {
    check_column(c);
  }
}

void check_shape_compatibility(table_view const& lhs, table_view const& rhs)
{
  CUDF_EXPECTS(lhs.num_columns() == rhs.num_columns(),
               "Cannot compare tables with different number of columns");
  for (size_type i = 0; i < lhs.num_columns(); ++i) {
    CUDF_EXPECTS(column_types_equivalent(lhs.column(i), rhs.column(i)),
                 "Cannot compare tables with different column types");
  }
}

}  // namespace

namespace row {

namespace lexicographic {

namespace {

/**
 * @brief Transform any nested lists-of-structs column into lists-of-integers column.
 *
 * For a lists-of-structs column at any nested level, its child structs column will be replaced by a
 * `size_type` column computed as its ranks.
 *
 * If the input column is not lists-of-structs, or does not contain lists-of-structs at any nested
 * level, the input will be passed through without any changes.
 *
 * @param lhs The input lhs column to transform
 * @param rhs The input rhs column to transform (if available)
 * @param column_null_order The flag indicating how nulls compare to non-null values
 * @param stream CUDA stream used for device memory operations and kernel launches
 * @return A tuple consisting of new column_view representing the transformed input, along with
 *         their ranks column(s) (of `size_type` type) and possibly new list offsets generated
 * during the transformation process
 */
std::tuple<column_view,
           std::optional<column_view>,
           std::vector<std::unique_ptr<column>>,
           std::vector<std::unique_ptr<column>>>
transform_lists_of_structs(column_view const& lhs,
                           std::optional<column_view> const& rhs_opt,
                           null_order column_null_order,
                           rmm::cuda_stream_view stream)
{
  auto const default_mr = rmm::mr::get_current_device_resource();

  // If the input is not sliced, just replace the input child by new_child.
  // Otherwise, we have to generate new offsets and replace both offsets/child of the input by the
  // new ones. This is because the new child here is generated by ranking and always has zero
  // offset thus cannot replace the input child if it is sliced.
  // The new offsets column needs to be returned and kept alive.
  auto const replace_child = [&](column_view const& input,
                                 column_view const& new_child,
                                 std::vector<std::unique_ptr<column>>& out_cols) {
    auto const make_output = [&input](auto const& offsets_cv, auto const& child_cv) {
      return column_view{data_type{type_id::LIST},
                         input.size(),
                         nullptr,
                         input.null_mask(),
                         input.null_count(),
                         0,
                         {offsets_cv, child_cv}};
    };

    if (input.offset() == 0) {
      return make_output(input.child(lists_column_view::offsets_column_index), new_child);
    }

    out_cols.emplace_back(
      cudf::lists::detail::get_normalized_offsets(lists_column_view{input}, stream, default_mr));
    return make_output(out_cols.back()->view(), new_child);
  };

  // Dense ranks should be used instead of first rank.
  // Consider this example: `input = [ [{0, "a"}, {3, "c"}], [{0, "a"}, {2, "b"}] ]`.
  // If first rank is used, `transformed_input = [ [0, 3], [1, 2] ]`. Comparing them will lead
  // to the result row(0) < row(1) which is incorrect.
  // With dense rank, `transformed_input = [ [0, 2], [0, 1] ]`, producing correct comparison.
  //
  // In addition, since the ranked structs column(s) are nested child column instead of
  // top-level column, the column order should be fixed to the same values in all situations.
  // For example, with the same input above, using the fixed values for column order
  // (`order::ASCENDING`), we have `transformed_input = [ [0, 2], [0, 1] ]`. Sorting of
  // `transformed_input` will produce the same result as sorting `input` regardless of sorting
  // order (ASC or DESC).
  auto const compute_ranks = [&](column_view const& input) {
    return cudf::detail::rank(input,
                              rank_method::DENSE,
                              order::ASCENDING,
                              null_policy::EXCLUDE,
                              column_null_order,
                              false /*percentage*/,
                              stream,
                              default_mr);
  };

  std::vector<std::unique_ptr<column>> out_cols_lhs;
  std::vector<std::unique_ptr<column>> out_cols_rhs;

  if (lhs.type().id() == type_id::LIST) {
    auto const child_lhs = cudf::lists_column_view{lhs}.get_sliced_child(stream);

    // Found a lists-of-structs column.
    if (child_lhs.type().id() == type_id::STRUCT) {
      if (rhs_opt) {  // rhs table is available
        auto const child_rhs = cudf::lists_column_view{rhs_opt.value()}.get_sliced_child(stream);
        auto const concatenated_children = cudf::detail::concatenate(
          std::vector<column_view>{child_lhs, child_rhs}, stream, default_mr);

        auto const ranks        = compute_ranks(concatenated_children->view());
        auto const ranks_slices = cudf::detail::slice(
          ranks->view(),
          {0, child_lhs.size(), child_lhs.size(), child_lhs.size() + child_rhs.size()},
          stream);

        out_cols_lhs.emplace_back(std::make_unique<column>(ranks_slices.front()));
        out_cols_rhs.emplace_back(std::make_unique<column>(ranks_slices.back()));

        auto transformed_lhs = replace_child(lhs, out_cols_lhs.back()->view(), out_cols_lhs);
        auto transformed_rhs =
          replace_child(rhs_opt.value(), out_cols_rhs.back()->view(), out_cols_rhs);

        return {std::move(transformed_lhs),
                std::optional<column_view>{std::move(transformed_rhs)},
                std::move(out_cols_lhs),
                std::move(out_cols_rhs)};
      } else {  // rhs table is not available
        out_cols_lhs.emplace_back(compute_ranks(child_lhs));
        auto transformed_lhs = replace_child(lhs, out_cols_lhs.back()->view(), out_cols_lhs);

        return {std::move(transformed_lhs),
                std::nullopt,
                std::move(out_cols_lhs),
                std::move(out_cols_rhs)};
      }
    }
    // Found a lists-of-lists column.
    else if (child_lhs.type().id() == type_id::LIST) {
      auto const child_rhs_opt =
        rhs_opt
          ? std::optional<column_view>{cudf::lists_column_view{rhs_opt.value()}.get_sliced_child(
              stream)}
          : std::nullopt;

      // Recursively call transformation on the child column.
      auto [new_child_lhs, new_child_rhs_opt, out_cols_child_lhs, out_cols_child_rhs] =
        transform_lists_of_structs(child_lhs, child_rhs_opt, column_null_order, stream);

      // Only transform the current pair of columns if their children have been transformed.
      if (out_cols_child_lhs.size() > 0 || out_cols_child_rhs.size() > 0) {
        out_cols_lhs.insert(out_cols_lhs.end(),
                            std::make_move_iterator(out_cols_child_lhs.begin()),
                            std::make_move_iterator(out_cols_child_lhs.end()));
        out_cols_rhs.insert(out_cols_rhs.end(),
                            std::make_move_iterator(out_cols_child_rhs.begin()),
                            std::make_move_iterator(out_cols_child_rhs.end()));

        auto transformed_lhs = replace_child(lhs, new_child_lhs, out_cols_lhs);
        if (rhs_opt) {
          auto transformed_rhs =
            replace_child(rhs_opt.value(), new_child_rhs_opt.value(), out_cols_rhs);

          return {std::move(transformed_lhs),
                  std::optional<column_view>{std::move(transformed_rhs)},
                  std::move(out_cols_lhs),
                  std::move(out_cols_rhs)};
        } else {
          return {std::move(transformed_lhs),
                  std::nullopt,
                  std::move(out_cols_lhs),
                  std::move(out_cols_rhs)};
        }
      }
    }
    // else == child is not STRUCT or LIST: just go to the end of this function, no transformation.
  }
  // Any structs-of-lists should be decomposed into empty struct type `Struct<>` before being
  // processed by this function.
  else if (lhs.type().id() == type_id::STRUCT) {
    CUDF_EXPECTS(std::all_of(lhs.child_begin(),
                             lhs.child_end(),
                             [](auto const& child) { return child.type().id() != type_id::LIST; }),
                 "Structs columns should be decomposed before reaching this function.");
  }

  // Passthrough: nothing changed.
  return {lhs, rhs_opt, std::move(out_cols_lhs), std::move(out_cols_rhs)};
}

/**
 * @brief Transform any nested lists-of-structs column in the given table(s) into lists-of-integers
 * column.
 *
 * If the rhs table is specified, its shape should be pre-checked to match with the shape of lhs
 * table using `check_shape_compatibility` before being passed into this function.
 *
 * @param lhs The input lhs table to transform
 * @param rhs The input rhs table to transform (if available)
 * @param null_precedence Optional, an array having the same length as the number of columns in
 *        the input tables that indicates how null values compare to all other. If it is empty,
 *        the order `null_order::BEFORE` will be used for all columns.
 * @param stream CUDA stream used for device memory operations and kernel launches
 * @return A tuple consisting of new table_view representing the transformed input, along with
 *         the ranks column (of `size_type` type) and possibly new list offsets generated during the
 *         transformation process
 */
std::tuple<table_view,
           std::optional<table_view>,
           std::vector<std::unique_ptr<column>>,
           std::vector<std::unique_ptr<column>>>
transform_lists_of_structs(table_view const& lhs,
                           std::optional<table_view> const& rhs,
                           host_span<null_order const> null_precedence,
                           rmm::cuda_stream_view stream)
{
  std::vector<column_view> transformed_lhs_cvs;
  std::vector<column_view> transformed_rhs_cvs;
  std::vector<std::unique_ptr<column>> out_cols_lhs;
  std::vector<std::unique_ptr<column>> out_cols_rhs;

  for (size_type col_idx = 0; col_idx < lhs.num_columns(); ++col_idx) {
    auto const& lhs_col = lhs.column(col_idx);
    auto const rhs_col_opt =
      rhs ? std::optional<column_view>{rhs.value().column(col_idx)} : std::nullopt;

    auto [transformed_lhs, transformed_rhs_opt, curr_out_cols_lhs, curr_out_cols_rhs] =
      transform_lists_of_structs(
        lhs_col,
        rhs_col_opt,
        null_precedence.empty() ? null_order::BEFORE : null_precedence[col_idx],
        stream);

    transformed_lhs_cvs.push_back(transformed_lhs);
    if (rhs) { transformed_rhs_cvs.push_back(transformed_rhs_opt.value()); }

    out_cols_lhs.insert(out_cols_lhs.end(),
                        std::make_move_iterator(curr_out_cols_lhs.begin()),
                        std::make_move_iterator(curr_out_cols_lhs.end()));
    out_cols_rhs.insert(out_cols_rhs.end(),
                        std::make_move_iterator(curr_out_cols_rhs.begin()),
                        std::make_move_iterator(curr_out_cols_rhs.end()));
  }

  return {table_view{transformed_lhs_cvs},
          rhs ? std::optional<table_view>{table_view{transformed_rhs_cvs}} : std::nullopt,
          std::move(out_cols_lhs),
          std::move(out_cols_rhs)};
}

/**
 * @brief Check if there is any lists-of-structs column in the input table that has a floating-point
 * column nested inside it.
 *
 * @param input The tables to check
 * @return The check result
 */
bool lists_of_structs_have_floating_point(table_view const& input)
{
  // Check if any (nested) column is floating-point type.
  std::function<bool(column_view const&)> const has_nested_floating_point = [&](auto const& col) {
    return col.type().id() == type_id::FLOAT32 || col.type().id() == type_id::FLOAT64 ||
           std::any_of(col.child_begin(), col.child_end(), has_nested_floating_point);
  };

  return std::any_of(input.begin(), input.end(), [&](auto const& col) {
    // Any structs-of-lists should be decomposed into empty struct type `Struct<>` before being
    // processed by this function.
    if (col.type().id() == type_id::STRUCT) {
      CUDF_EXPECTS(
        std::all_of(col.child_begin(),
                    col.child_end(),
                    [](auto const& child) { return child.type().id() != type_id::LIST; }),
        "Structs columns should be decomposed before reaching this function.");
    }

    // We are looking for lists-of-structs.
    if (col.type().id() != type_id::LIST) { return false; }

    auto const child = col.child(lists_column_view::child_column_index);
    if (child.type().id() == type_id::STRUCT &&
        std::any_of(child.child_begin(), child.child_end(), has_nested_floating_point)) {
      return true;
    }
    if (child.type().id() == type_id::LIST &&
        lists_of_structs_have_floating_point(table_view{{child}})) {
      return true;
    }

    // Found a lists column of some-type other than STRUCT or LIST.
    return false;
  });
}

uint64_t generate_random_id()
{
  auto gen = std::mt19937{std::random_device{}()};
  std::uniform_int_distribution<uint64_t> dis;
  return dis(gen);
}

}  // namespace

std::shared_ptr<preprocessed_table> preprocessed_table::create_preprocessed_table(
  table_view const& preprocessed_input,
  std::vector<int>&& verticalized_col_depths,
  std::vector<std::unique_ptr<column>>&& structs_transformed_columns,
  host_span<order const> column_order,
  host_span<null_order const> null_precedence,
  uint64_t preprocessed_id,
  bool ranked_floating_point,
  rmm::cuda_stream_view stream)
{
  check_lex_compatibility(preprocessed_input);

  auto d_t = table_device_view::create(preprocessed_input, stream);
  auto d_column_order =
    detail::make_device_uvector_async(column_order, stream, rmm::mr::get_current_device_resource());
  auto d_null_precedence = detail::make_device_uvector_async(
    null_precedence, stream, rmm::mr::get_current_device_resource());
  auto d_depths = detail::make_device_uvector_async(
    verticalized_col_depths, stream, rmm::mr::get_current_device_resource());

  if (detail::has_nested_columns(preprocessed_input)) {
    auto [dremel_data, d_dremel_device_view] = list_lex_preprocess(preprocessed_input, stream);
    return std::shared_ptr<preprocessed_table>(
      new preprocessed_table(std::move(d_t),
                             std::move(d_column_order),
                             std::move(d_null_precedence),
                             std::move(d_depths),
                             std::move(dremel_data),
                             std::move(d_dremel_device_view),
                             std::move(structs_transformed_columns),
                             preprocessed_id,
                             ranked_floating_point));
  } else {
    return std::shared_ptr<preprocessed_table>(
      new preprocessed_table(std::move(d_t),
                             std::move(d_column_order),
                             std::move(d_null_precedence),
                             std::move(d_depths),
                             std::move(structs_transformed_columns),
                             preprocessed_id,
                             ranked_floating_point));
  }
}

std::shared_ptr<preprocessed_table> preprocessed_table::create(
  table_view const& input,
  host_span<order const> column_order,
  host_span<null_order const> null_precedence,
  rmm::cuda_stream_view stream)
{
  auto [decomposed_input, new_column_order, new_null_precedence, verticalized_col_depths] =
    decompose_structs(input, false /*no decompose lists*/, column_order, null_precedence);

  // Unused variables are generated for rhs table which is not available here.
  [[maybe_unused]] auto [transformed_t, unused_0, structs_transformed_columns, unused_1] =
    transform_lists_of_structs(decomposed_input, std::nullopt, new_null_precedence, stream);

  auto const ranked_floating_point = structs_transformed_columns.size() > 0 &&
                                     lists_of_structs_have_floating_point(decomposed_input);
  return create_preprocessed_table(transformed_t,
                                   std::move(verticalized_col_depths),
                                   std::move(structs_transformed_columns),
                                   new_column_order,
                                   new_null_precedence,
                                   generate_random_id(),
                                   ranked_floating_point,
                                   stream);
}

std::pair<std::shared_ptr<preprocessed_table>, std::shared_ptr<preprocessed_table>>
preprocessed_table::create(table_view const& lhs,
                           table_view const& rhs,
                           host_span<order const> column_order,
                           host_span<null_order const> null_precedence,
                           rmm::cuda_stream_view stream)
{
  check_shape_compatibility(lhs, rhs);

  auto [decomposed_lhs,
        new_column_order_lhs,
        new_null_precedence_lhs,
        verticalized_col_depths_lhs] =
    decompose_structs(lhs, false /*no decompose lists*/, column_order, null_precedence);

  // Unused variables are new column order and null order for rhs, which are the same as for lhs
  // so we don't need them.
  [[maybe_unused]] auto [decomposed_rhs, unused0, unused1, verticalized_col_depths_rhs] =
    decompose_structs(rhs, false /*no decompose lists*/, column_order, null_precedence);

  // Transform any (nested) lists-of-structs column into lists-of-integers column.
  auto [transformed_lhs,
        transformed_rhs_opt,
        structs_transformed_columns_lhs,
        structs_transformed_columns_rhs] =
    transform_lists_of_structs(decomposed_lhs, decomposed_rhs, new_null_precedence_lhs, stream);

  // This should be the same for both lhs and rhs but not all the time, such as when one table
  // has 0 rows  so we check separately for each of them.
  auto const ranked_floating_point_lhs = structs_transformed_columns_lhs.size() > 0 &&
                                         lists_of_structs_have_floating_point(decomposed_lhs);
  auto const ranked_floating_point_rhs = structs_transformed_columns_rhs.size() > 0 &&
                                         lists_of_structs_have_floating_point(decomposed_rhs);
  auto const preprocessed_id = generate_random_id();

  return {create_preprocessed_table(transformed_lhs,
                                    std::move(verticalized_col_depths_lhs),
                                    std::move(structs_transformed_columns_lhs),
                                    new_column_order_lhs,
                                    new_null_precedence_lhs,
                                    preprocessed_id,
                                    ranked_floating_point_lhs,
                                    stream),
          create_preprocessed_table(transformed_rhs_opt.value(),
                                    std::move(verticalized_col_depths_rhs),
                                    std::move(structs_transformed_columns_rhs),
                                    new_column_order_lhs,
                                    new_null_precedence_lhs,
                                    preprocessed_id,
                                    ranked_floating_point_rhs,
                                    stream)};
}

preprocessed_table::preprocessed_table(
  table_device_view_owner&& table,
  rmm::device_uvector<order>&& column_order,
  rmm::device_uvector<null_order>&& null_precedence,
  rmm::device_uvector<size_type>&& depths,
  std::vector<detail::dremel_data>&& dremel_data,
  rmm::device_uvector<detail::dremel_device_view>&& dremel_device_views,
  std::vector<std::unique_ptr<column>>&& structs_transformed_columns,
  uint64_t preprocessed_id,
  bool ranked_floating_point)
  : _t(std::move(table)),
    _column_order(std::move(column_order)),
    _null_precedence(std::move(null_precedence)),
    _depths(std::move(depths)),
    _dremel_data(std::move(dremel_data)),
    _dremel_device_views(std::move(dremel_device_views)),
    _structs_transformed_columns(std::move(structs_transformed_columns)),
    _preprocessed_id(preprocessed_id),
    _ranked_floating_point(ranked_floating_point)
{
}

preprocessed_table::preprocessed_table(
  table_device_view_owner&& table,
  rmm::device_uvector<order>&& column_order,
  rmm::device_uvector<null_order>&& null_precedence,
  rmm::device_uvector<size_type>&& depths,
  std::vector<std::unique_ptr<column>>&& structs_transformed_columns,
  uint64_t preprocessed_id,
  bool ranked_floating_point)
  : _t(std::move(table)),
    _column_order(std::move(column_order)),
    _null_precedence(std::move(null_precedence)),
    _depths(std::move(depths)),
    _dremel_data{},
    _dremel_device_views{},
    _structs_transformed_columns(std::move(structs_transformed_columns)),
    _preprocessed_id(preprocessed_id),
    _ranked_floating_point(ranked_floating_point)
{
}

two_table_comparator::two_table_comparator(table_view const& left,
                                           table_view const& right,
                                           host_span<order const> column_order,
                                           host_span<null_order const> null_precedence,
                                           rmm::cuda_stream_view stream)
{
  std::tie(d_left_table, d_right_table) =
    preprocessed_table::create(left, right, column_order, null_precedence, stream);
}

}  // namespace lexicographic

namespace equality {

std::shared_ptr<preprocessed_table> preprocessed_table::create(table_view const& t,
                                                               rmm::cuda_stream_view stream)
{
  check_eq_compatibility(t);

  auto [null_pushed_table, nullable_data] =
    structs::detail::push_down_nulls(t, stream, rmm::mr::get_current_device_resource());
  auto struct_offset_removed_table = remove_struct_child_offsets(null_pushed_table);
  auto verticalized_t =
    std::get<0>(decompose_structs(struct_offset_removed_table, true /*decompose lists*/));

  auto d_t = table_device_view_owner(table_device_view::create(verticalized_t, stream));
  return std::shared_ptr<preprocessed_table>(new preprocessed_table(
    std::move(d_t), std::move(nullable_data.new_null_masks), std::move(nullable_data.new_columns)));
}

two_table_comparator::two_table_comparator(table_view const& left,
                                           table_view const& right,
                                           rmm::cuda_stream_view stream)
  : d_left_table{preprocessed_table::create(left, stream)},
    d_right_table{preprocessed_table::create(right, stream)}
{
  check_shape_compatibility(left, right);
}

}  // namespace equality

}  // namespace row
}  // namespace experimental
}  // namespace cudf
