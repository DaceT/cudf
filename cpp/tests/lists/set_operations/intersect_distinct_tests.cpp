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

#include <cudf_test/base_fixture.hpp>
#include <cudf_test/column_utilities.hpp>
#include <cudf_test/column_wrapper.hpp>
#include <cudf_test/iterator_utilities.hpp>
#include <cudf_test/type_lists.hpp>

#include <cudf/column/column_factories.hpp>
#include <cudf/lists/set_operations.hpp>
#include <cudf/lists/sorting.hpp>
#include <cudf/lists/stream_compaction.hpp>
#include <cudf/null_mask.hpp>

#include <limits>
#include <string>

using float_type = double;
using namespace cudf::test::iterators;

auto constexpr null{0};  // null at current level
auto constexpr XXX{0};   // null pushed down from parent level
auto constexpr neg_NaN      = -std::numeric_limits<float_type>::quiet_NaN();
auto constexpr neg_Inf      = -std::numeric_limits<float_type>::infinity();
auto constexpr NaN          = std::numeric_limits<float_type>::quiet_NaN();
auto constexpr Inf          = std::numeric_limits<float_type>::infinity();
auto constexpr NULL_EQUAL   = cudf::null_equality::EQUAL;
auto constexpr NULL_UNEQUAL = cudf::null_equality::UNEQUAL;
auto constexpr NAN_EQUAL    = cudf::nan_equality::ALL_EQUAL;
auto constexpr NAN_UNEQUAL  = cudf::nan_equality::UNEQUAL;

using bools_col     = cudf::test::fixed_width_column_wrapper<bool>;
using int32s_col    = cudf::test::fixed_width_column_wrapper<int32_t>;
using floats_lists  = cudf::test::lists_column_wrapper<float_type>;
using strings_lists = cudf::test::lists_column_wrapper<cudf::string_view>;
using strings_col   = cudf::test::strings_column_wrapper;
using structs_col   = cudf::test::structs_column_wrapper;
using lists_cv      = cudf::lists_column_view;

namespace {
auto set_intersect_sorted(cudf::column_view const& lhs,
                          cudf::column_view const& rhs,
                          cudf::null_equality nulls_equal = NULL_EQUAL,
                          cudf::nan_equality nans_equal   = NAN_EQUAL)
{
  auto const results =
    cudf::lists::intersect_distinct(lists_cv{lhs}, lists_cv{rhs}, nulls_equal, nans_equal);
  return cudf::lists::sort_lists(
    lists_cv{*results}, cudf::order::ASCENDING, cudf::null_order::BEFORE);
}
}  // namespace

struct SetIntersectTest : public cudf::test::BaseFixture {
};

template <typename T>
struct SetIntersectTypedTest : public cudf::test::BaseFixture {
};

using TestTypes =
  cudf::test::Concat<cudf::test::IntegralTypesNotBool, cudf::test::FloatingPointTypes>;

TYPED_TEST_SUITE(SetIntersectTypedTest, TestTypes);

TEST_F(SetIntersectTest, TrivialTest)
{
  auto const lhs =
    floats_lists{{floats_lists{{NaN, 5.0, 0.0, 0.0, 0.0, 0.0, null, 0.0}, null_at(6)},
                  floats_lists{{NaN, 5.0, 0.0, 0.0, 0.0, 0.0, null, 1.0}, null_at(6)},
                  {} /*NULL*/,
                  floats_lists{{NaN, 5.0, 0.0, 0.0, 0.0, 0.0, null, 1.0}, null_at(6)}},
                 null_at(2)};
  auto const rhs =
    floats_lists{{floats_lists{{1.0, 0.5, null, 0.0, 0.0, null, NaN}, nulls_at({2, 5})},
                  floats_lists{{2.0, 1.0, null, 0.0, 0.0, null}, nulls_at({2, 5})},
                  floats_lists{{2.0, 1.0, null, 0.0, 0.0, null}, nulls_at({2, 5})},
                  {} /*NULL*/},
                 null_at(3)};
  auto const expected = floats_lists{{floats_lists{{null, 0.0, NaN}, null_at(0)},
                                      floats_lists{{null, 0.0, 1.0}, null_at(0)},
                                      floats_lists{} /*NULL*/,
                                      floats_lists{} /*NULL*/},
                                     nulls_at({2, 3})};

  auto const results_sorted = set_intersect_sorted(lhs, rhs);
  CUDF_TEST_EXPECT_COLUMNS_EQUIVALENT(expected, *results_sorted);
}

TEST_F(SetIntersectTest, TrivialIdentityTest)
{
  auto const input =
    floats_lists{{floats_lists{{NaN, 5.0, 0.0, 0.0, 0.0, 0.0, null, 0.0}, null_at(6)},
                  floats_lists{{NaN, 5.0, 0.0, 0.0, 0.0, 0.0, null, 1.0}, null_at(6)},
                  {} /*NULL*/,
                  floats_lists{{NaN, 5.0, 0.0, 0.0, 0.0, 0.0, null, 1.0}, null_at(6)}},
                 null_at(2)};

  // `intersect_distinct(input, input) <==> lists::distinct(input)`.
  auto const input_distinct        = cudf::lists::distinct(lists_cv{input});
  auto const input_distinct_sorted = cudf::lists::sort_lists(
    lists_cv{*input_distinct}, cudf::order::ASCENDING, cudf::null_order::BEFORE);

  auto const results_sorted = set_intersect_sorted(input, input);
  CUDF_TEST_EXPECT_COLUMNS_EQUIVALENT(*input_distinct_sorted, *results_sorted);
}

TEST_F(SetIntersectTest, FloatingPointTestsWithSignedZero)
{
  // -0.0 and 0.0 should be considered equal.
  auto const lhs      = floats_lists{{0.0, 0.0, 0.0, 0.0, 0.0}, {-0.0, 1.0}, {0.0}};
  auto const rhs      = floats_lists{{-0.0, -0.0, -0.0, -0.0, -0.0}, {0.0, 2.0}, {1.0}};
  auto const expected = floats_lists{floats_lists{0}, floats_lists{0}, floats_lists{}};

  auto const results_sorted = set_intersect_sorted(lhs, rhs);
  CUDF_TEST_EXPECT_COLUMNS_EQUAL(expected, *results_sorted);
}

TEST_F(SetIntersectTest, FloatingPointTestsWithInf)
{
  auto const lhs      = floats_lists{{Inf, Inf, Inf}, {Inf, 0.0, neg_Inf}};
  auto const rhs      = floats_lists{{neg_Inf, neg_Inf}, {0.0, Inf}};
  auto const expected = floats_lists{floats_lists{}, floats_lists{0.0, Inf}};

  auto const results_sorted = set_intersect_sorted(lhs, rhs);
  CUDF_TEST_EXPECT_COLUMNS_EQUAL(expected, *results_sorted);
}

TEST_F(SetIntersectTest, FloatingPointTestsWithNaNs)
{
  auto const lhs =
    floats_lists{{0, -1, 1, NaN}, {2, 0, neg_NaN}, {1, -2, 2, 0, 1, 2}, {NaN, NaN, NaN, NaN, NaN}};
  auto const rhs =
    floats_lists{{2, 3, 4, neg_NaN}, {2, 0}, {neg_NaN, 1, -2, 2, 0, 1, 2}, {neg_NaN, neg_NaN}};

  // NaNs are equal.
  {
    auto const expected       = floats_lists{{NaN}, {0, 2}, {-2, 0, 1, 2}, {NaN}};
    auto const results_sorted = set_intersect_sorted(lhs, rhs, NULL_EQUAL, NAN_EQUAL);
    CUDF_TEST_EXPECT_COLUMNS_EQUAL(expected, *results_sorted);
  }

  // NaNs are unequal.
  {
    auto const expected       = floats_lists{{}, {0, 2}, {-2, 0, 1, 2}, {}};
    auto const results_sorted = set_intersect_sorted(lhs, rhs, NULL_EQUAL, NAN_UNEQUAL);
    CUDF_TEST_EXPECT_COLUMNS_EQUAL(expected, *results_sorted);
  }
}

TEST_F(SetIntersectTest, StringTestsNonNull)
{
  // Trivial cases - empty input.
  {
    auto const lhs      = strings_lists{};
    auto const rhs      = strings_lists{};
    auto const expected = strings_lists{};

    auto const results_sorted = set_intersect_sorted(lhs, rhs);
    CUDF_TEST_EXPECT_COLUMNS_EQUAL(expected, *results_sorted);
  }

  // Trivial cases - empty input.
  {
    auto const lhs      = strings_lists{strings_lists{}};
    auto const rhs      = strings_lists{strings_lists{}};
    auto const expected = strings_lists{strings_lists{}};

    auto const results_sorted = set_intersect_sorted(lhs, rhs);
    CUDF_TEST_EXPECT_COLUMNS_EQUAL(expected, *results_sorted);
  }

  // No overlap.
  {
    auto const lhs      = strings_lists{"this", "is", "a", "string"};
    auto const rhs      = strings_lists{"aha", "bear", "blow", "heat"};
    auto const expected = strings_lists{strings_lists{}};

    auto const results_sorted = set_intersect_sorted(lhs, rhs);
    CUDF_TEST_EXPECT_COLUMNS_EQUAL(expected, *results_sorted);
  }

  // One list column.
  {
    auto const lhs      = strings_lists{"this", "is", "a", "string"};
    auto const rhs      = strings_lists{"a", "delicious", "banana"};
    auto const expected = strings_lists{"a"};

    auto const results_sorted = set_intersect_sorted(lhs, rhs);
    CUDF_TEST_EXPECT_COLUMNS_EQUAL(expected, *results_sorted);
  }

  // Multiple lists column.
  {
    auto const lhs      = strings_lists{strings_lists{"one", "two", "three"},
                                   strings_lists{"four", "five", "six"},
                                   strings_lists{"1", "2", "3"}};
    auto const rhs      = strings_lists{strings_lists{"one", "banana"},
                                   strings_lists{"apple", "kiwi", "cherry"},
                                   strings_lists{"two", "and", "1"}};
    auto const expected = strings_lists{strings_lists{"one"}, strings_lists{}, strings_lists{"1"}};

    auto const results_sorted = set_intersect_sorted(lhs, rhs);
    CUDF_TEST_EXPECT_COLUMNS_EQUAL(expected, *results_sorted);
  }
}

TEST_F(SetIntersectTest, StringTestsWithNullsEqual)
{
  auto const null = std::string("");

  // One list column with null entries.
  {
    auto const lhs = strings_lists{
      {"this", null, "is", "is", "is", "a", null, "string", null, "string"}, nulls_at({1, 6, 8})};
    auto const rhs =
      strings_lists{{"aha", null, "abc", null, "1111", null, "2222"}, nulls_at({1, 3, 5})};
    auto const expected = strings_lists{{null}, null_at(0)};

    auto const results_sorted = set_intersect_sorted(lhs, rhs, NULL_EQUAL);
    CUDF_TEST_EXPECT_COLUMNS_EQUIVALENT(expected, *results_sorted);
  }

  // Multiple lists column with null lists and null entries.
  {
    auto const lhs = strings_lists{
      strings_lists{{"this", null, "is", null, "a", null, null, "string"}, nulls_at({1, 3, 5, 6})},
      strings_lists{},
      strings_lists{"this", "is", "a", "string"}};
    auto const rhs = strings_lists{
      {strings_lists{{"aha", null, "abc", null, "1111", null, "2222"}, nulls_at({1, 3, 5})},
       strings_lists{}, /* NULL */
       strings_lists{"aha", "this", "is another", "string???"}},
      null_at(1)};
    auto const expected = strings_lists{
      {strings_lists{{null}, null_at(0)}, strings_lists{} /*NULL*/, strings_lists{"this"}},
      null_at(1)};

    auto const results_sorted = set_intersect_sorted(lhs, rhs, NULL_EQUAL);
    CUDF_TEST_EXPECT_COLUMNS_EQUAL(expected, *results_sorted);
  }
}

TEST_F(SetIntersectTest, StringTestsWithNullsUnequal)
{
  auto const null = std::string("");

  // One list column with null entries.
  {
    auto const lhs = strings_lists{
      {"this", null, "is", "is", "is", "a", null, "string", null, "string"}, nulls_at({1, 6, 8})};
    auto const rhs =
      strings_lists{{"aha", null, "abc", null, "1111", null, "2222"}, nulls_at({1, 3, 5})};
    auto const expected = strings_lists{strings_lists{}};

    auto const results_sorted = set_intersect_sorted(lhs, rhs, NULL_UNEQUAL);
    CUDF_TEST_EXPECT_COLUMNS_EQUAL(expected, *results_sorted);
  }

  // Multiple lists column with null lists and null entries.
  {
    auto const lhs = strings_lists{
      strings_lists{{"this", null, "is", null, "a", null, null, "string"}, nulls_at({1, 3, 5, 6})},
      strings_lists{},
      strings_lists{"this", "is", "a", "string"}};
    auto const rhs = strings_lists{
      {strings_lists{{"aha", null, "abc", null, "1111", null, "2222"}, nulls_at({1, 3, 5})},
       strings_lists{}, /* NULL */
       strings_lists{"aha", "this", "is another", "string???"}},
      null_at(1)};
    auto const expected = [] {
      auto str_lists =
        strings_lists{{strings_lists{}, strings_lists{} /*NULL*/, strings_lists{"this"}},
                      null_at(1)}
          .release();
      auto& child = str_lists->child(cudf::lists_column_view::child_column_index);
      child.set_null_mask(cudf::create_null_mask(child.size(), cudf::mask_state::ALL_VALID), 0);
      return str_lists;
    }();

    auto const results_sorted = set_intersect_sorted(lhs, rhs, NULL_UNEQUAL);
    CUDF_TEST_EXPECT_COLUMNS_EQUAL(*expected, *results_sorted);
  }
}

TYPED_TEST(SetIntersectTypedTest, TrivialInputTests)
{
  using lists_col = cudf::test::lists_column_wrapper<TypeParam>;

  // Empty input.
  {
    auto const lhs      = lists_col{};
    auto const rhs      = lists_col{};
    auto const expected = lists_col{};

    auto const results_sorted = set_intersect_sorted(lhs, rhs);
    CUDF_TEST_EXPECT_COLUMNS_EQUAL(expected, *results_sorted);
  }

  // All input lists are empty.
  {
    auto const lhs      = lists_col{lists_col{}, lists_col{}, lists_col{}};
    auto const rhs      = lists_col{lists_col{}, lists_col{}, lists_col{}};
    auto const expected = lists_col{lists_col{}, lists_col{}, lists_col{}};

    auto const results_sorted = set_intersect_sorted(lhs, rhs);
    CUDF_TEST_EXPECT_COLUMNS_EQUAL(expected, *results_sorted);
  }

  // Multiple empty lists.
  {
    auto const lhs      = lists_col{{}, {1, 2}, {}, {5, 4, 3, 2, 1, 0}, {}, {6}, {}};
    auto const rhs      = lists_col{{}, {}, {0}, {0, 1, 2, 3, 4, 5}, {}, {6, 7}, {}};
    auto const expected = lists_col{{}, {}, {}, {0, 1, 2, 3, 4, 5}, {}, {6}, {}};

    auto const results_sorted = set_intersect_sorted(lhs, rhs);
    CUDF_TEST_EXPECT_COLUMNS_EQUAL(expected, *results_sorted);
  }
}

TYPED_TEST(SetIntersectTypedTest, SlicedNonNullInputTests)
{
  using lists_col = cudf::test::lists_column_wrapper<TypeParam>;

  auto const lhs_original =
    lists_col{{1, 2, 3, 2, 3, 2, 3, 2, 3}, {3, 2, 1, 4, 1}, {5}, {10, 8, 9}, {6, 7}};
  auto const rhs_original =
    lists_col{{1, 2, 3, 2, 3, 2, 3, 2, 3}, {5, 6, 7, 8, 7, 5}, {}, {1, 2, 3}, {6, 7}};

  {
    auto const expected = lists_col{{1, 2, 3}, {}, {}, {}, {6, 7}};

    auto const results_sorted = set_intersect_sorted(lhs_original, rhs_original);
    CUDF_TEST_EXPECT_COLUMNS_EQUAL(expected, *results_sorted);
  }

  {
    auto const lhs      = cudf::slice(lhs_original, {1, 5})[0];
    auto const rhs      = cudf::slice(rhs_original, {1, 5})[0];
    auto const expected = lists_col{{}, {}, {}, {6, 7}};

    auto const results_sorted = set_intersect_sorted(lhs, rhs);
    CUDF_TEST_EXPECT_COLUMNS_EQUAL(expected, *results_sorted);
  }

  {
    auto const lhs      = cudf::slice(lhs_original, {1, 3})[0];
    auto const rhs      = cudf::slice(rhs_original, {1, 3})[0];
    auto const expected = lists_col{lists_col{}, lists_col{}};

    auto const results_sorted = set_intersect_sorted(lhs, rhs);
    CUDF_TEST_EXPECT_COLUMNS_EQUAL(expected, *results_sorted);
  }

  {
    auto const lhs      = cudf::slice(lhs_original, {0, 3})[0];
    auto const rhs      = cudf::slice(rhs_original, {0, 3})[0];
    auto const expected = lists_col{{1, 2, 3}, {}, {}};

    auto const results_sorted = set_intersect_sorted(lhs, rhs);
    CUDF_TEST_EXPECT_COLUMNS_EQUAL(expected, *results_sorted);
  }
}

TYPED_TEST(SetIntersectTypedTest, InputHaveNullsTests)
{
  using lists_col     = cudf::test::lists_column_wrapper<TypeParam>;
  auto constexpr null = TypeParam{0};

  // Nullable lists.
  {
    auto const lhs = lists_col{{{3, 2, 1, 4, 1}, {5}, {} /*NULL*/, {} /*NULL*/, {10, 8, 9}, {6, 7}},
                               nulls_at({2, 3})};
    auto const rhs =
      lists_col{{{1, 2}, {} /*NULL*/, {3}, {} /*NULL*/, {10, 11, 12}, {1, 2}}, nulls_at({1, 3})};
    auto const expected =
      lists_col{{{1, 2}, {} /*NULL*/, {} /*NULL*/, {} /*NULL*/, {10}, {}}, nulls_at({1, 2, 3})};

    auto const results_sorted = set_intersect_sorted(lhs, rhs);
    CUDF_TEST_EXPECT_COLUMNS_EQUAL(expected, *results_sorted);
  }

  // Nullable child and nulls are equal.
  {
    auto const lhs = lists_col{lists_col{{null, 1, null, 3}, nulls_at({0, 2})},
                               lists_col{{null, 5}, null_at(0)},
                               lists_col{{null, 7, null, 9}, nulls_at({0, 2})}};
    auto const rhs = lists_col{lists_col{{null, null, 5}, nulls_at({0, 1})},
                               lists_col{{5, null}, null_at(1)},
                               lists_col{7, 8, 9}};
    auto const expected =
      lists_col{lists_col{{null}, null_at(0)}, lists_col{{null, 5}, null_at(0)}, lists_col{7, 9}};

    auto const results_sorted = set_intersect_sorted(lhs, rhs, NULL_EQUAL);
    CUDF_TEST_EXPECT_COLUMNS_EQUAL(expected, *results_sorted);
  }

  // Nullable child and nulls are unequal.
  {
    auto const lhs      = lists_col{lists_col{{null, 1, null, 3}, nulls_at({0, 2})},
                               lists_col{{null, 5}, null_at(0)},
                               lists_col{{null, 7, null, 9}, nulls_at({0, 2})}};
    auto const rhs      = lists_col{lists_col{{null, null, 5}, nulls_at({0, 1})},
                               lists_col{{5, null}, null_at(1)},
                               lists_col{7, 8, 9}};
    auto const expected = lists_col{lists_col{}, lists_col{5}, lists_col{7, 9}};

    auto const results_sorted = set_intersect_sorted(lhs, rhs, NULL_UNEQUAL);
    CUDF_TEST_EXPECT_COLUMNS_EQUIVALENT(expected, *results_sorted);
  }
}

TEST_F(SetIntersectTest, InputListsOfNestedStructsHaveNull)
{
  auto const get_structs_lhs = [] {
    auto grandchild1 = int32s_col{{
                                    1,    XXX,  null, XXX, XXX, 1, 1,    1,  // list1
                                    1,    1,    1,    1,   2,   1, null, 2,  // list2
                                    null, null, 2,    2,   3,   2, 3,    3   // list3
                                  },
                                  nulls_at({2, 14, 16, 17})};
    auto grandchild2 = strings_col{{
                                     // begin list1
                                     "Banana",
                                     "YYY", /*NULL*/
                                     "Apple",
                                     "XXX", /*NULL*/
                                     "YYY", /*NULL*/
                                     "Banana",
                                     "Cherry",
                                     "Kiwi",  // end list1
                                              // begin list2
                                     "Bear",
                                     "Duck",
                                     "Cat",
                                     "Dog",
                                     "Panda",
                                     "Bear",
                                     "" /*NULL*/,
                                     "Panda",  // end list2
                                               // begin list3
                                     "ÁÁÁ",
                                     "ÉÉÉÉÉ",
                                     "ÍÍÍÍÍ",
                                     "ÁBC",
                                     "" /*NULL*/,
                                     "ÁÁÁ",
                                     "ÁBC",
                                     "XYZ"  // end list3
                                   },
                                   nulls_at({14, 20})};
    auto child1      = structs_col{{grandchild1, grandchild2}, nulls_at({1, 3, 4})};
    return structs_col{{child1}};
  };

  // Only grandchild1 of rhs is different from lhs'. The rest is exactly the same.
  auto const get_structs_rhs = [] {
    auto grandchild1 = int32s_col{{
                                    2,    XXX,  null, XXX, XXX, 2, 2,    2,  // list1
                                    3,    3,    3,    3,   3,   3, null, 3,  // list2
                                    null, null, 4,    4,   4,   4, 4,    4   // list3
                                  },
                                  nulls_at({2, 14, 16, 17})};
    auto grandchild2 = strings_col{{
                                     // begin list1
                                     "Banana",
                                     "YYY", /*NULL*/
                                     "Apple",
                                     "XXX", /*NULL*/
                                     "YYY", /*NULL*/
                                     "Banana",
                                     "Cherry",
                                     "Kiwi",  // end list1
                                              // begin list2
                                     "Bear",
                                     "Duck",
                                     "Cat",
                                     "Dog",
                                     "Panda",
                                     "Bear",
                                     "" /*NULL*/,
                                     "Panda",  // end list2
                                               // begin list3
                                     "ÁÁÁ",
                                     "ÉÉÉÉÉ",
                                     "ÍÍÍÍÍ",
                                     "ÁBC",
                                     "" /*NULL*/,
                                     "ÁÁÁ",
                                     "ÁBC",
                                     "XYZ"  // end list3
                                   },
                                   nulls_at({14, 20})};
    auto child1      = structs_col{{grandchild1, grandchild2}, nulls_at({1, 3, 4})};
    return structs_col{{child1}};
  };

  // Nulls are equal.
  {
    auto const get_structs_expected = [] {
      auto grandchild1 = int32s_col{{
                                      null,
                                      null,  // end list1
                                      null,  // end list2
                                      null,
                                      null  // end list3
                                    },
                                    all_nulls()};
      auto grandchild2 = strings_col{{
                                       "" /*NULL*/,
                                       "Apple",      // end list1
                                       "" /*NULL*/,  // end list2
                                       "ÁÁÁ",
                                       "ÉÉÉÉÉ"  // end list3
                                     },
                                     nulls_at({0, 2})};
      auto child1      = structs_col{{grandchild1, grandchild2}, null_at(0)};
      return structs_col{{child1}};
    };

    auto const lhs = cudf::make_lists_column(
      3, int32s_col{0, 8, 16, 24}.release(), get_structs_lhs().release(), 0, {});
    auto const rhs = cudf::make_lists_column(
      3, int32s_col{0, 8, 16, 24}.release(), get_structs_rhs().release(), 0, {});
    auto const expected = cudf::make_lists_column(
      3, int32s_col{0, 2, 3, 5}.release(), get_structs_expected().release(), 0, {});

    auto const results_sorted = set_intersect_sorted(*lhs, *rhs, NULL_EQUAL);
    CUDF_TEST_EXPECT_COLUMNS_EQUIVALENT(*expected, *results_sorted);
  }

  // Nulls are unequal.
  {
    auto const get_structs_expected = [] {
      auto grandchild1 = int32s_col{};
      auto grandchild2 = strings_col{};
      auto child1      = structs_col{{grandchild1, grandchild2}};
      return structs_col{{child1}};
    };

    auto const lhs = cudf::make_lists_column(
      3, int32s_col{0, 8, 16, 24}.release(), get_structs_lhs().release(), 0, {});
    auto const rhs = cudf::make_lists_column(
      3, int32s_col{0, 8, 16, 24}.release(), get_structs_rhs().release(), 0, {});
    auto const expected = cudf::make_lists_column(
      3, int32s_col{0, 0, 0, 0}.release(), get_structs_expected().release(), 0, {});

    auto const results_sorted = set_intersect_sorted(*lhs, *rhs, NULL_UNEQUAL);
    CUDF_TEST_EXPECT_COLUMNS_EQUAL(*expected, *results_sorted);
  }
}

TEST_F(SetIntersectTest, InputListsOfStructsOfLists)
{
  auto const lhs = [] {
    auto const get_structs = [] {
      auto child1 = int32s_col{// begin list1
                               0,
                               1,
                               2,  // end list1
                                   // begin list2
                               3,  // end list2
                                   // begin list3
                               4,
                               5,
                               6};
      auto child2 = floats_lists{// begin list1
                                 floats_lists{0, 1},
                                 floats_lists{0, 2},
                                 floats_lists{1, 1},     // end list1
                                                         // begin list2
                                 floats_lists{3, 4, 5},  // end list2
                                                         // begin list3
                                 floats_lists{6, 7},
                                 floats_lists{6, 8},
                                 floats_lists{6, 7, 8}};
      return structs_col{{child1, child2}};
    };

    return cudf::make_lists_column(
      3, int32s_col{0, 3, 4, 7}.release(), get_structs().release(), 0, {});
  }();

  auto const rhs = [] {
    auto const get_structs = [] {
      auto child1 = int32s_col{// begin list1
                               0,
                               1,
                               2,  // end list1
                                   // begin list2
                               3,  // end list2
                                   // begin list3
                               4,
                               5,
                               6};
      auto child2 = floats_lists{// begin list1
                                 floats_lists{1, 1},
                                 floats_lists{0, 2},
                                 floats_lists{1, 2},     // end list1
                                                         // begin list2
                                 floats_lists{3, 4, 5},  // end list2
                                                         // begin list3
                                 floats_lists{6, 7, 8, 9},
                                 floats_lists{6, 8},
                                 floats_lists{3, 4, 5}};
      return structs_col{{child1, child2}};
    };

    return cudf::make_lists_column(
      3, int32s_col{0, 3, 4, 7}.release(), get_structs().release(), 0, {});
  }();

  auto const expected = [] {
    auto const get_structs = [] {
      auto child1 = int32s_col{1, 3, 5};
      auto child2 = floats_lists{floats_lists{0, 2}, floats_lists{3, 4, 5}, floats_lists{6, 8}};
      return structs_col{{child1, child2}};
    };

    return cudf::make_lists_column(
      3, int32s_col{0, 1, 2, 3}.release(), get_structs().release(), 0, {});
  }();

  auto const results = cudf::lists::intersect_distinct(lists_cv{*lhs}, lists_cv{*rhs});
  CUDF_TEST_EXPECT_COLUMNS_EQUAL(*expected, *results);
}
