import Config

#### Extension-specific compile-time configuration goes here, everything else should be in `Bonfire.WordPress.RuntimeConfig`

# how often an imported site is checked for posts gone from it (unpublished or deleted there), which are then hidden here; the check's schedule runs hourly, so shorter than an hour has no effect
config :bonfire_wordpress, removal_check_every: to_timeout(day: 1)
