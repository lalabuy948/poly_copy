defmodule Polyx.Polymarket.GammaTest do
  use ExUnit.Case, async: true

  # Test parsing functions that don't require API calls
  # These are private functions, so we test them through public API behavior
  # or by testing edge cases with mocked data

  describe "get_categories/0" do
    test "returns list of categories with required fields" do
      categories = Polyx.Polymarket.Gamma.get_categories()

      assert is_list(categories)
      assert length(categories) > 0

      for category <- categories do
        assert Map.has_key?(category, :id)
        assert Map.has_key?(category, :label)
        assert Map.has_key?(category, :keywords)
        assert is_list(category.keywords)
        assert length(category.keywords) > 0
      end
    end

    test "includes expected categories" do
      categories = Polyx.Polymarket.Gamma.get_categories()
      category_ids = Enum.map(categories, & &1.id)

      assert "politics" in category_ids
      assert "crypto" in category_ids
      assert "sports" in category_ids
    end
  end

  describe "get_market_by_token/1" do
    test "returns error for invalid token_id" do
      assert {:error, :invalid_token_id} = Polyx.Polymarket.Gamma.get_market_by_token(nil)
      assert {:error, :invalid_token_id} = Polyx.Polymarket.Gamma.get_market_by_token(123)
      assert {:error, :invalid_token_id} = Polyx.Polymarket.Gamma.get_market_by_token(%{})
    end
  end
end
