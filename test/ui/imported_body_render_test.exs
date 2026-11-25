defmodule Bonfire.WordPress.ImportedBodyRenderTest do
  @moduledoc """
  A post imported from a WordPress site shows its body as stored: a block's figure and caption are on its page, as the site showed them, and nothing that could run.
  """
  use Bonfire.WordPress.ConnCase, async: false
  import PhoenixTest

  @moduletag :ui

  setup do
    Tesla.Mock.mock_global(fn _ -> %Tesla.Env{status: 404, body: ""} end)

    account = fake_account!()
    me = fake_user!(account)

    {:ok, me: me, conn: conn(user: me, account: account)}
  end

  test "an image block's figure and caption show on the post's page", %{me: me, conn: conn} do
    link = "https://blog.example.local/a-block/"

    assert {:ok, _} =
             Bonfire.WordPress.Posts.import_post(
               %{
                 title: "A post with a block",
                 link: link,
                 published_at: ~U[2020-05-04 10:00:00Z],
                 html:
                   ~s|<p>Intro</p><figure class="wp-block-image alignleft"><img src="https://blog.example.local/wp-content/uploads/a.jpg" alt="Market"><figcaption class="wp-element-caption">The market</figcaption></figure><script>alert(1)</script><p>Outro</p>|,
                 author: nil
               },
               current_user: me
             )

    assert {:ok, %{id: id}} = Bonfire.Federate.ActivityPub.Peered.get_by_uri(link)

    conn
    |> visit("/post/#{id}")
    |> wait_async()
    |> assert_has("figure.wp-block-image figcaption", text: "The market")
    |> refute_has("script", text: "alert(1)")
  end
end
