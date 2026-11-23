defmodule Bonfire.WordPress.PostsTest do
  @moduledoc """
  Importing one WordPress post, from wherever it came (an export file, the site's REST API, a ping): a post by its author's user here, its body sanitised, dated when it was published on the site, and linked to where it came from.
  """
  use Bonfire.WordPress.DataCase, async: false
  import Bonfire.Me.Fake
  alias Bonfire.Common.Repo
  alias Bonfire.Common.DatesTimes
  alias Bonfire.WordPress.Posts

  setup do
    # no request should reach a real site
    Tesla.Mock.mock_global(fn _ -> %Tesla.Env{status: 404, body: ""} end)

    {:ok, me: fake_user!()}
  end

  defp post(attrs) do
    Map.merge(
      %{
        title: "A post from the site",
        link: "https://blog.example.local/a-post-from-the-site/",
        published_at: ~U[2020-05-04 10:00:00Z],
        html: "<p>Hello from the site</p><script>alert('x')</script>",
        author: %{
          login: "Jo Writer",
          email: "jo-writer@blog.example.local",
          display_name: "Jo Writer"
        }
      },
      attrs
    )
  end

  defp imported(link) do
    assert {:ok, %{id: id}} = Bonfire.Federate.ActivityPub.Peered.get_by_uri(link)

    %{
      id: id,
      content: Repo.get!(Bonfire.Data.Social.PostContent, id),
      creator_id: Repo.get!(Bonfire.Data.Social.Created, id).creator_id
    }
  end

  test "a post comes in with its title and sanitised body, dated and linked as on the site, by its author's user",
       %{me: me} do
    post = post(%{})
    assert {:ok, _} = Posts.import_post(post, current_user: me)

    %{id: id, content: content, creator_id: creator_id} = imported(post.link)

    assert content.name == post.title
    assert content.html_body =~ "Hello from the site"
    refute content.html_body =~ "<script"
    assert DateTime.compare(DatesTimes.to_date_time(%{id: id}), post.published_at) == :eq

    assert %{} = account = Bonfire.Me.Accounts.get_by_email(post.author.email)
    assert [%{id: user_id}] = Bonfire.Me.Users.by_account!(account)
    assert creator_id == user_id
  end

  test "a post imported again isn't published a second time", %{me: me} do
    post = post(%{link: "https://blog.example.local/imported-twice/"})

    assert {:ok, _} = Posts.import_post(post, current_user: me)
    assert {:ok, _} = Posts.import_post(post, current_user: me)

    assert Repo.aggregate(
             from(pc in Bonfire.Data.Social.PostContent, where: pc.name == ^post.title),
             :count
           ) == 1
  end

  # a later sync must not bring in what a source only shows behind a password
  test "a post behind a password is refused, and nothing is published", %{me: me} do
    post = post(%{link: "https://blog.example.local/members-only/", password_protected?: true})

    assert {:error, :password_protected} = Posts.import_post(post, current_user: me)
    assert {:error, _} = Bonfire.Federate.ActivityPub.Peered.get_by_uri(post.link)
  end

  test "a post with no author comes in as the importing person's", %{me: me} do
    post = post(%{author: nil, link: "https://blog.example.local/no-author/"})
    assert {:ok, _} = Posts.import_post(post, current_user: me)

    assert imported(post.link).creator_id == me.id
  end

  # the site's REST API sends titles HTML-encoded (eg. `It&#8217;s`): one comes in as the same title typed here would be stored
  test "an HTML-encoded title comes in as that title typed here", %{me: me} do
    post = post(%{title: "It&#8217;s &amp; more", link: "https://blog.example.local/entities/"})
    assert {:ok, _} = Posts.import_post(post, current_user: me)

    assert imported(post.link).content.name ==
             Bonfire.Social.PostContents.prepare_text("It’s & more", me, [])
  end

  # A title is rendered with `rich/1`, which outputs one starting with `<` as HTML without sanitising it again, so an encoded `&lt;script&gt;` in a title must not be stored as a real `<script>`. Failing as of 2026-11-23: the title pipeline (`PostContents.prepare_text/3` → `Text.as_html`) decodes it into markup; not caused by the import.
  test "encoded markup in a title is stored as text, not as markup", %{me: me} do
    post =
      post(%{
        title: "&lt;script&gt;alert(1)&lt;/script&gt; Safe",
        link: "https://blog.example.local/encoded-markup/"
      })

    assert {:ok, _} = Posts.import_post(post, current_user: me)
    refute imported(post.link).content.name =~ "<script"
  end

  # the media stays where it is on the site: attached as links to its files there, the primary one as the post's image
  test "a post's media is attached at its addresses on the site, the primary one as its image",
       %{me: me} do
    image = "https://blog.example.local/wp-content/uploads/cover.jpg"
    audio = "https://blog.example.local/wp-content/uploads/episode.mp3"

    post =
      post(%{
        link: "https://blog.example.local/with-media/",
        media: [
          %{url: image, media_type: "image/jpeg", alt: "The cover", primary?: true},
          %{url: audio, media_type: "audio/mpeg", alt: nil, primary?: false}
        ]
      })

    assert {:ok, _} = Posts.import_post(post, current_user: me)

    assert {:ok, imported} =
             Bonfire.Common.Needles.get(imported(post.link).id, skip_boundary_check: true)

    media =
      imported
      |> Repo.preload([files: :media], force: true)
      |> Map.get(:files)
      |> Map.new(&{&1.media.path, &1.media})

    assert %{} = cover = media[image]
    assert (cover.metadata["primary_image"] || cover.metadata[:primary_image]) == true
    assert Bonfire.Files.Media.media_alt(cover, false) == "The cover"

    assert %{media_type: media_type} = media[audio]
    assert media_type =~ "audio"
  end

  # an imported body unfurls as any post does: a bare URL in its text gets a preview, a link inside `<a href>` doesn't. The links use a real TLD, since link detection ignores `.local` hosts (mocked, so nothing leaves the machine)
  test "in an imported body, a bare URL is unfurled as in any post, a link inside <a href> isn't",
       %{me: me} do
    {:ok, requests} = Agent.start_link(fn -> [] end)

    Tesla.Mock.mock_global(fn %{url: url} ->
      Agent.update(requests, &[url | &1])
      %Tesla.Env{status: 404, body: ""}
    end)

    link = "https://blog.example.local/a-post-with-links/"

    assert {:ok, _} =
             Posts.import_post(
               post(%{
                 link: link,
                 html:
                   ~s(<p>A <a href="https://elsewhere.example.com/linked">linked page</a>, and a bare one: https://elsewhere.example.com/bare</p>)
               }),
               current_user: me
             )

    assert imported(link)

    requested = Agent.get(requests, & &1)
    assert Enum.any?(requested, &String.contains?(&1, "elsewhere.example.com/bare"))
    refute Enum.any?(requested, &String.contains?(&1, "elsewhere.example.com/linked"))
  end

  # the control for the test above: a post typed here unfurls a bare URL in its text the same way, so the import isn't a special case
  test "a bare URL in a post typed here is unfurled", %{me: me} do
    {:ok, requests} = Agent.start_link(fn -> [] end)

    Tesla.Mock.mock_global(fn %{url: url} ->
      Agent.update(requests, &[url | &1])
      %Tesla.Env{status: 404, body: ""}
    end)

    assert {:ok, _} =
             Bonfire.Posts.publish(
               current_user: me,
               boundary: "public",
               post_attrs: %{
                 post_content: %{html_body: "A bare one: https://elsewhere.example.com/bare"}
               }
             )

    assert Agent.get(requests, & &1)
           |> Enum.any?(&String.contains?(&1, "elsewhere.example.com/bare"))
  end
end
