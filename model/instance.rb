module Plugin::Worldon
  class Instance < Diva::Model
    register :worldon_instance, name: "Mastodonインスタンス(Worldon)"

    field.string :domain, required: true
    field.string :client_key, required: true
    field.string :client_secret, required: true
    field.bool :retrieve, required: true

    class << self
      def datasource_slug(domain, type)
        case type
        when :local
          # ローカルTL
          "worldon-#{domain}-local".to_sym
        when :local_media
          # ローカルメディアTL
          "worldon-#{domain}-local-media".to_sym
        when :federated
          # 連合TL
          "worldon-#{domain}-federated".to_sym
        when :federated_media
          # 連合メディアTL
          "worldon-#{domain}-federated-media".to_sym
        end
      end

      def datasource_slug_inv(sym)
        s = sym.to_s
        r = %r!\Aworldon-(.*)-(local(?:-media)?|federated(?:-media)?)\z!
        m = r.match s
        return nil if !m

        domain = m[1]
        type = m[2].gsub("-", "_").to_sym

        return [domain, type]
      end

      def add_datasources(domain)
        Plugin[:worldon].filter_extract_datasources do |dss|
          datasources = {
            datasource_slug(domain, :local) => "Mastodon公開タイムライン(Worldon)/#{domain} ローカル",
            datasource_slug(domain, :local_media) => "Mastodon公開タイムライン(Worldon)/#{domain} ローカル（メディア）",
            datasource_slug(domain, :federated) => "Mastodon公開タイムライン(Worldon)/#{domain} 連合",
            datasource_slug(domain, :federated_media) => "Mastodon公開タイムライン(Worldon)/#{domain} 連合（メディア）",
          }
          [datasources.merge(dss)]
        end
      end

      def remove_datasources(domain)
        Plugin[:worldon].filter_extract_datasources do |datasources|
          datasources.delete datasource_slug(domain, :local)
          datasources.delete datasource_slug(domain, :local_media)
          datasources.delete datasource_slug(domain, :federated)
          datasources.delete datasource_slug(domain, :federated_media)
          [datasources]
        end
      end

      def add(domain, retrieve = true)
        return nil if UserConfig[:worldon_instances].has_key?(domain)

        resp = Plugin::Worldon::API.call(:post, domain, '/api/v1/apps',
                                         client_name: Plugin::Worldon::CLIENT_NAME,
                                         redirect_uris: 'urn:ietf:wg:oauth:2.0:oob',
                                         scopes: 'read write follow',
                                         website: Plugin::Worldon::WEB_SITE
                                        )
        return nil if resp.nil?
        add_datasources(domain)

        self.new(
          domain: domain,
          client_key: resp[:client_id],
          client_secret: resp[:client_secret],
          retrieve: retrieve,
        ).store
      end

      def load(domain)
        if UserConfig[:worldon_instances][domain].nil?
          nil
        else
          self.new(
            domain: domain,
            client_key: UserConfig[:worldon_instances][domain][:client_key],
            client_secret: UserConfig[:worldon_instances][domain][:client_secret],
            retrieve: UserConfig[:worldon_instances][domain][:retrieve],
          )
        end
      end

      def remove(domain)
        remove_datasources(domain)
        UserConfig[:worldon_instances].delete(domain)
      end

      def domains
        UserConfig[:worldon_instances].keys.dup
      end

      def settings
        UserConfig[:worldon_instances].map do |domain, value|
          { domain: domain, retrieve: value[:retrieve] }
        end
      end
    end # class instance

    def store
      configs = UserConfig[:worldon_instances].dup
      configs[domain] = { client_key: client_key, client_secret: client_secret, retrieve: retrieve }
      UserConfig[:worldon_instances] = configs
      self
    end

    def authorize_url
      params = URI.encode_www_form({
        scope: 'read write follow',
        response_type: 'code',
        redirect_uri: 'urn:ietf:wg:oauth:2.0:oob',
        client_id: client_key
      })
      'https://' + domain + '/oauth/authorize?' + params
    end

    def inspect
      "worldon-instance(#{domain})"
    end

  end
end
