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

# Contact info and license
author: Tarek Loubani <tarek@tarek.org>
license: aGPLv3

