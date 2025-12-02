defmodule PolyxWeb.HomeLiveTest do
  use PolyxWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  describe "HomeLive" do
    test "renders the copy trading interface", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/")

      assert html =~ "Copy Trading"
      assert html =~ "Tracked Wallets"
      assert html =~ "Trade Sizing"
      assert has_element?(view, "#add-user-form")
      assert has_element?(view, "#settings-form")
    end

    test "can add a user to track", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      # Add a user
      view
      |> form("#add-user-form", %{
        "address" => "0x1234567890abcdef1234567890abcdef12345678",
        "label" => "Test User"
      })
      |> render_submit()

      # Verify user appears in the list
      assert render(view) =~ "Test User"
      assert render(view) =~ "0x1234"
    end

    test "can archive a tracked user", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      # First add a user
      view
      |> form("#add-user-form", %{
        "address" => "0xabcdef1234567890abcdef1234567890abcdef12",
        "label" => "Archive Me"
      })
      |> render_submit()

      assert render(view) =~ "Archive Me"
      # Verify it's in the tracked users section (has archive button)
      assert has_element?(
               view,
               "button[phx-click=archive_user][phx-value-address='0xabcdef1234567890abcdef1234567890abcdef12']"
             )

      # Now archive the user
      view
      |> element(
        "button[phx-click=archive_user][phx-value-address='0xabcdef1234567890abcdef1234567890abcdef12']"
      )
      |> render_click()

      # Verify archive button is gone (user is no longer in active list)
      refute has_element?(
               view,
               "button[phx-click=archive_user][phx-value-address='0xabcdef1234567890abcdef1234567890abcdef12']"
             )

      # Verify user is now in archived section with restore button
      assert has_element?(
               view,
               "button[phx-click=restore_user][phx-value-address='0xabcdef1234567890abcdef1234567890abcdef12']"
             )
    end

    test "can toggle copy trading enabled/disabled", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/")

      # Initially should be paused
      assert html =~ "Paused"

      # Click toggle button
      view
      |> element("button[phx-click=toggle_enabled]")
      |> render_click()

      assert render(view) =~ "Live"
    end

    test "can update sizing settings", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      # Change to fixed mode with a new amount
      view
      |> form("#settings-form", %{
        "sizing_mode" => "fixed",
        "fixed_amount" => "25",
        "proportional_factor" => "0.1",
        "percentage" => "5.0"
      })
      |> render_change()

      # Verify settings are updated
      html = render(view)
      assert html =~ "$25 fixed"
    end
  end
end
