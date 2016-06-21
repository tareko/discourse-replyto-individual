# name: replyto-individual plugin
# about: A plugin that allows exposure of the sender's email address for functionality
#        similar to GNU/Mailman's Reply_Goes_To_List = Poster
# version: 0.0.1
# authors: Tarek Loubani <tarek@tarek.org>
# license: aGPLv3

PLUGIN_NAME ||= "replyto-individual".freeze


after_initialize do
  Email::MessageBuilder.class_eval do

    def header_args
      result = {}
      if @opts[:add_unsubscribe_link]
        result['List-Unsubscribe'] = "<#{template_args[:user_preferences_url]}>"
      end
  
      if @opts[:mark_as_reply_to_auto_generated]
        result[REPLY_TO_AUTO_GENERATED_HEADER_KEY] = REPLY_TO_AUTO_GENERATED_HEADER_VALUE
      end
  
      result['X-Discourse-Post-Id'] = @opts[:post_id].to_s if @opts[:post_id]
      result['X-Discourse-Topic-Id'] = @opts[:topic_id].to_s if @opts[:topic_id]
  
      if allow_reply_by_email?
        result['X-Discourse-Reply-Key'] = reply_key
        if @opts[:private_reply] == true
          result['Reply-To'] = reply_by_email_address
        else
          p = Post.find_by_id @opts[:post_id]
          result['Reply-To'] = "#{p.user.name} <#{p.user.email}>"
          result['CC'] = reply_by_email_address
        end
      else
        result['Reply-To'] = from_value
      end
  
      result.merge(Email::MessageBuilder.custom_headers(SiteSetting.email_custom_headers))
    end
  end
end
