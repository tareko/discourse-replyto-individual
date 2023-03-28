# name: replyto-individual plugin
# about: A plugin that allows exposure of the sender's email address for functionality
#        similar to GNU/Mailman's Reply_Goes_To_List = Poster
# version: 0.1
# authors: Tarek Loubani <tarek@>
# license: aGPLv3

PLUGIN_NAME ||= "replyto-individual".freeze


after_initialize do
  Email::MessageBuilder.class_eval do
    attr_reader :template_args

    ALLOW_REPLY_BY_EMAIL_HEADER = 'X-Discourse-Allow-Reply-By-Email'.freeze

    def build_args
      args = {
        to: @to,
        subject: subject,
        body: body,
        charset: 'UTF-8',
        from: from_value,
        cc: @opts[:cc]
      }
       args[:cc] = reply_by_email_address

      args[:delivery_method_options] = @opts[:delivery_method_options] if @opts[:delivery_method_options]
      args[:delivery_method_options] = (args[:delivery_method_options] || {}).merge(return_response: true)

      args
    end
    
    def header_args
      result = {}
      if @opts[:add_unsubscribe_link]
        unsubscribe_url = @template_args[:unsubscribe_url].presence || @template_args[:user_preferences_url]
        result['List-Unsubscribe'] = "<#{unsubscribe_url}>"
      end

      result['X-Discourse-Post-Id']  = @opts[:post_id].to_s  if @opts[:post_id]
      result['X-Discourse-Topic-Id'] = @opts[:topic_id].to_s if @opts[:topic_id]

      # please, don't send us automatic responses...
      result['X-Auto-Response-Suppress'] = 'All'

      if !allow_reply_by_email?
        # This will end up being the notification_email, which is a
        # noreply address.
        result['Reply-To'] = from_value
      else

        # The only reason we use from address for reply to is for group
        # SMTP emails, where the person will be replying to the group's
        # email_username.
        if !@opts[:use_from_address_for_reply_to]
          result[ALLOW_REPLY_BY_EMAIL_HEADER] = true
          p = Post.find_by_id @opts[:post_id]
          result['Reply-To'] = "#{p.user.name} <#{p.user.email}>"
          
        else
          # No point in adding a reply-to header if it is going to be identical
          # to the from address/alias. If the from option is not present, then
          # the default reply-to address is used.
          result['Reply-To'] = from_value if from_value != alias_email(@opts[:from])
        end
      end

      result.merge(Email::MessageBuilder.custom_headers(SiteSetting.email_custom_headers))
    end
    
    def self.custom_headers(string)
      result = {}
      string.split('|').each { |item|
        header = item.split(':', 2)
# Not sure what the purpose here is, but it kills the CCs, so I'm blanking it for now.'
#        if header.length == 2
#          name = header[0].strip
#          value = header[1].strip
#          result[name] = value if name.length > 0 && value.length > 0
#        end
      } unless string.nil?
      result
    end
  end
  
  
  # Fix the Email::Sender method to also insert the reply_key into CC

  Email::Sender.class_eval do
    def send
      bypass_disable = BYPASS_DISABLE_TYPES.include?(@email_type.to_s)

      if SiteSetting.disable_emails == "yes" && !bypass_disable
        return
      end

      return if ActionMailer::Base::NullMail === @message
      return if ActionMailer::Base::NullMail === (@message.message rescue nil)

      return skip(SkippedEmailLog.reason_types[:sender_message_blank])    if @message.blank?
      return skip(SkippedEmailLog.reason_types[:sender_message_to_blank]) if @message.to.blank?

      if SiteSetting.disable_emails == "non-staff" && !bypass_disable
        return unless find_user&.staff?
      end

      return skip(SkippedEmailLog.reason_types[:sender_message_to_invalid]) if to_address.end_with?(".invalid")

      if @message.text_part
        if @message.text_part.body.to_s.blank?
          return skip(SkippedEmailLog.reason_types[:sender_text_part_body_blank])
        end
      else
        if @message.body.to_s.blank?
          return skip(SkippedEmailLog.reason_types[:sender_body_blank])
        end
      end

      @message.charset = 'UTF-8'

      opts = {}

      renderer = Email::Renderer.new(@message, opts)

      if @message.html_part
        @message.html_part.body = renderer.html
      else
        @message.html_part = Mail::Part.new do
          content_type 'text/html; charset=UTF-8'
          body renderer.html
        end
      end

      # Fix relative (ie upload) HTML links in markdown which do not work well in plain text emails.
      # These are the links we add when a user uploads a file or image.
      # Ideally we would parse general markdown into plain text, but that is almost an intractable problem.
      url_prefix = Discourse.base_url
      @message.parts[0].body = @message.parts[0].body.to_s.gsub(/<a class="attachment" href="(\/uploads\/default\/[^"]+)">([^<]*)<\/a>/, '[\2|attachment](' + url_prefix + '\1)')
      @message.parts[0].body = @message.parts[0].body.to_s.gsub(/<img src="(\/uploads\/default\/[^"]+)"([^>]*)>/, '![](' + url_prefix + '\1)')

      @message.text_part.content_type = 'text/plain; charset=UTF-8'
      user_id = @user&.id

      # Set up the email log
      email_log = EmailLog.new(
        email_type: @email_type,
        to_address: to_address,
        user_id: user_id
      )

      if cc_addresses.any?
        email_log.cc_addresses = cc_addresses.join(";")
        email_log.cc_user_ids = User.with_email(cc_addresses).pluck(:id)
      end

      host = Email::Sender.host_for(Discourse.base_url)

      post_id   = header_value('X-Discourse-Post-Id')
      topic_id  = header_value('X-Discourse-Topic-Id')
      reply_key = get_reply_key(post_id, user_id)
      from_address = @message.from&.first
      smtp_group_id = from_address.blank? ? nil : Group.where(
        email_username: from_address, smtp_enabled: true
      ).pluck_first(:id)

      # always set a default Message ID from the host
      @message.header['Message-ID'] = Email::MessageIdService.generate_default

      if topic_id.present? && post_id.present?
        post = Post.find_by(id: post_id, topic_id: topic_id)

        # guards against deleted posts and topics
        return skip(SkippedEmailLog.reason_types[:sender_post_deleted]) if post.blank?

        topic = post.topic
        return skip(SkippedEmailLog.reason_types[:sender_topic_deleted]) if topic.blank?

        add_attachments(post)

        # If the topic was created from an incoming email, then the Message-ID from
        # that email will be the canonical reference, otherwise the canonical reference
        # will be <topic/TOPIC_ID@host>. The canonical reference is used in the
        # References header.
        #
        # This is so the sender of the original email still gets their nice threading
        # maintained (because their mail client will initiate threading based on
        # the Message-ID it generated) in the case where there is an incoming email.
        #
        # In the latter case, everyone will start their thread with the canonical reference,
        # because we send it in the References header for all emails.
        topic_canonical_reference_id = Email::MessageIdService.generate_default(
          topic, canonical: true, use_incoming_email_if_present: true
        )

        referenced_posts = Post.includes(:incoming_email)
          .joins("INNER JOIN post_replies ON post_replies.post_id = posts.id ")
          .where("post_replies.reply_post_id = ?", post_id)
          .order(id: :desc)

        referenced_post_message_ids = referenced_posts.map do |referenced_post|
          if referenced_post.incoming_email&.message_id.present?
            "<#{referenced_post.incoming_email.message_id}>"
          else
            if referenced_post.post_number == 1
              topic_canonical_reference_id
            else
              Email::MessageIdService.generate_for_post(referenced_post)
            end
          end
        end

        # See https://www.ietf.org/rfc/rfc2822.txt for the message format
        # specification, more useful information can be found in Email::MessageIdService
        #
        # The References header is how mail clients handle threading. The Message-ID
        # must always be unique.
        if post.post_number == 1
          @message.header['Message-ID']  = Email::MessageIdService.generate_default(topic)
          @message.header['References']  = [topic_canonical_reference_id]
        else
          @message.header['Message-ID']  = Email::MessageIdService.generate_for_post(post)
          @message.header['In-Reply-To'] = referenced_post_message_ids[0] || topic_canonical_reference_id
          @message.header['References']  = [topic_canonical_reference_id, referenced_post_message_ids].flatten.compact.uniq
        end

        # See https://www.ietf.org/rfc/rfc2919.txt for the List-ID
        # specification.
        if topic&.category && !topic.category.uncategorized?
          list_id = "#{SiteSetting.title} | #{topic.category.name} <#{topic.category.name.downcase.tr(' ', '-')}.#{host}>"

          # subcategory case
          if !topic.category.parent_category_id.nil?
            parent_category_name = Category.find_by(id: topic.category.parent_category_id).name
            list_id = "#{SiteSetting.title} | #{parent_category_name} #{topic.category.name} <#{topic.category.name.downcase.tr(' ', '-')}.#{parent_category_name.downcase.tr(' ', '-')}.#{host}>"
          end
        else
          list_id = "#{SiteSetting.title} <#{host}>"
        end

        # When we are emailing people from a group inbox, we are having a PM
        # conversation with them, as a support account would. In this case
        # mailing list headers do not make sense. It is not like a forum topic
        # where you may have tens or hundreds of participants -- it is a
        # conversation between the group and a small handful of people
        # directly contacting the group, often just one person.
        if !smtp_group_id

          # https://www.ietf.org/rfc/rfc3834.txt
          @message.header['Precedence'] = 'list'
          @message.header['List-ID']    = list_id

          if topic
            if SiteSetting.private_email?
              @message.header['List-Archive'] = "#{Discourse.base_url}#{topic.slugless_url}"
            else
              @message.header['List-Archive'] = topic.url
            end
          end
        end
      end

      if Email::Sender.bounceable_reply_address?
        email_log.bounce_key = SecureRandom.hex

        # WARNING: RFC claims you can not set the Return Path header, this is 100% correct
        # however Rails has special handling for this header and ends up using this value
        # as the Envelope From address so stuff works as expected
        @message.header[:return_path] = Email::Sender.bounce_address(email_log.bounce_key)
      end

      email_log.post_id = post_id if post_id.present?
      email_log.topic_id = topic_id if topic_id.present?

      # Remove headers we don't need anymore
      @message.header['X-Discourse-Topic-Id'] = nil if topic_id.present?
      @message.header['X-Discourse-Post-Id']  = nil if post_id.present?

      if reply_key.present?
        @message.header['Reply-To'] = header_value('Reply-To').gsub("%{reply_key}", reply_key)
        if !header_value('CC').blank?
            # This is done to bypass the header stripping that exists for some odd reason.
        	@message.header['CC'] =
        	header_value('CC').gsub("%{reply_key}", reply_key)
    	end
        @message.header[Email::MessageBuilder::ALLOW_REPLY_BY_EMAIL_HEADER] = nil
      end

      Email::MessageBuilder.custom_headers(SiteSetting.email_custom_headers).each do |key, _|
        # Any custom headers added via MessageBuilder that are doubled up here
        # with values that we determine should be set to the last value, which is
        # the one we determined. Our header values should always override the email_custom_headers.
        #
        # While it is valid via RFC5322 to have more than one value for certain headers,
        # we just want to keep it to one, especially in cases where the custom value
        # would conflict with our own.
        #
        # See https://datatracker.ietf.org/doc/html/rfc5322#section-3.6 and
        # https://github.com/mikel/mail/blob/8ef377d6a2ca78aa5bd7f739813f5a0648482087/lib/mail/header.rb#L109-L132
        custom_header = @message.header[key]
        if custom_header.is_a?(Array)
          our_value = custom_header.last.value

          # Must be set to nil first otherwise another value is just added
          # to the array of values for the header.
          @message.header[key] = nil
          @message.header[key] = our_value
        end

        value = header_value(key)

        # Remove Auto-Submitted header for group private message emails, it does
        # not make sense there and may hurt deliverability.
        #
        # From https://www.iana.org/assignments/auto-submitted-keywords/auto-submitted-keywords.xhtml:
        #
        # > Indicates that a message was generated by an automatic process, and is not a direct response to another message.
        if key.downcase == "auto-submitted" && smtp_group_id
          @message.header[key] = nil
        end

        # Replace reply_key in custom headers or remove
        if value&.include?('%{reply_key}')
          # Delete old header first or else the same header will be added twice
          @message.header[key] = nil
          if reply_key.present?
            @message.header[key] = value.gsub!('%{reply_key}', reply_key)
          end
        end
      end

      # pass the original message_id when using mailjet/mandrill/sparkpost
      case ActionMailer::Base.smtp_settings[:address]
      when /\.mailjet\.com/
        @message.header['X-MJ-CustomID'] = @message.message_id
      when "smtp.mandrillapp.com"
        merge_json_x_header('X-MC-Metadata', message_id: @message.message_id)
      when "smtp.sparkpostmail.com"
        merge_json_x_header('X-MSYS-API', metadata: { message_id: @message.message_id })
      end

      # Parse the HTML again so we can make any final changes before
      # sending
      style = Email::Styles.new(@message.html_part.body.to_s)

      # Suppress images from short emails
      if SiteSetting.strip_images_from_short_emails &&
        @message.html_part.body.to_s.bytesize <= SiteSetting.short_email_length &&
        @message.html_part.body =~ /<img[^>]+>/
        style.strip_avatars_and_emojis
      end

      # Embeds any of the secure images that have been attached inline,
      # removing the redaction notice.
      if SiteSetting.secure_uploads_allow_embed_images_in_emails
        style.inline_secure_images(@message.attachments, @message_attachments_index)
      end

      @message.html_part.body = style.to_s

      email_log.message_id = @message.message_id

      # Log when a message is being sent from a group SMTP address, so we
      # can debug deliverability issues.
      if smtp_group_id
        email_log.smtp_group_id = smtp_group_id

        # Store contents of all outgoing emails using group SMTP
        # for greater visibility and debugging. If the size of this
        # gets out of hand, we should look into a group-level setting
        # to enable this; size should be kept in check by regular purging
        # of EmailLog though.
        email_log.raw = Email::Cleaner.new(@message).execute
      end

      DiscourseEvent.trigger(:before_email_send, @message, @email_type)

      begin
        message_response = @message.deliver!

        # TestMailer from the Mail gem does not return a real response, it
        # returns an array containing @message, so we have to have this workaround.
        if message_response.kind_of?(Net::SMTP::Response)
          email_log.smtp_transaction_response = message_response.message&.chomp
        end
      rescue *SMTP_CLIENT_ERRORS => e
        return skip(SkippedEmailLog.reason_types[:custom], custom_reason: e.message)
      end

      email_log.save!
      email_log
    end
  end
end
