# Reply to individual

This discourse plugin allows Discourse's emails to mimic the GNU/Mailman 
option "reply_goes_to_list = Poster"

In practice, the plugin does the following:

1. It adds a `Reply-To:` header that exposes the poster's email address
2. It adds a `CC:` header that allows a 'Reply-All' action in a mailing agent
to respond back to the Discourse topic
3. It replaces all instances of "Reply" with "Reply All" in the client

Future directions:
* Stop "Reply All" from appearing in private messages
* Add "Reply" button that starts private message with poster
* Create option to not expose user emails by having private messages created
  instead of reply via email.
  
# Setting up a development environment
* Follow instructions [from here](https://meta.discourse.org/t/beginners-guide-to-install-discourse-for-development-using-docker/102009) for a docker-based environment
* Start mailhog: `d/mailhog`
* In [`email settings`](http://localhost:4200/admin/site_settings/category/email), set the following:
 * `email time window mins` = 0
 * `reply by email enabled` = enabled
 * `reply by email address` = replies+%{reply_key}@example.com
 * `manual polling enabled` = enabled
* In [`user preferences`](http://localhost:4200/admin/site_settings/category/user_preferences), set the following:
 * `default email mailing list mode` = enabled
 * `disable mailing list mode` = disabled

# Contact info and license
author: Tarek Loubani <tarek@tarek.org>
license: aGPLv3

