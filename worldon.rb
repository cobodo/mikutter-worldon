# -*- coding: utf-8 -*-
require 'pp'

module Plugin::Worldon
  PM = Plugin::Worldon
  CLIENT_NAME = 'mikutter Worldon'
  WEB_SITE = 'https://github.com/cobodo/mikutter-worldon'
end

require_relative 'util'
require_relative 'api'
require_relative 'parser'
require_relative 'model/model'
require_relative 'patch'
require_relative 'spell'
require_relative 'setting'
require_relative 'subparts_status_info'
require_relative 'extractcondition'
require_relative 'sse_client'
require_relative 'sse_stream'
require_relative 'rest'
require_relative 'score'

Plugin.create(:worldon) do
  pm = Plugin::Worldon

  defimageopener('Mastodon添付画像', %r<\Ahttps?://[^/]+/system/media_attachments/files/[0-9]{3}/[0-9]{3}/[0-9]{3}/\w+/\w+\.\w+(?:\?\d+)?\Z>) do |url|
    open(url)
  end

  defimageopener('Mastodon添付画像（短縮）', %r<\Ahttps?://[^/]+/media/[0-9A-Za-z_-]+(?:\?\d+)?\Z>) do |url|
    open(url)
  end

  defimageopener('Mastodon添付画像(proxy)', %r<\Ahttps?://[^/]+/media_proxy/[0-9]+/(?:original|small)\z>) do |url|
    open(url)
  end

  defevent :worldon_appear_toots, prototype: [[pm::Status]]

  filter_extract_datasources do |dss|
    datasources = { worldon_appear_toots: "受信したすべてのトゥート(Worldon)" }
    [datasources.merge(dss)]
  end

  on_extract_load_more_datasource do |tl_slug, source, oldest|
    notice "worldon: load more #{source} from #{oldest&.uri} #{oldest.inspect}"
    s = source.to_s
    next unless s.start_with?("worldon-") # 「すべてのトゥート」は遡れないことにする
    next unless oldest.class.slug == :worldon_status

    if s.end_with?("-local", "-local-media", "-federated", "-federated-media")
      Plugin.call(:worldon_load_more_public_timeline, tl_slug, source, oldest)
    else
      Plugin.call(:worldon_load_more_auth_timeline, tl_slug, source, oldest)
    end
  end

  on_worldon_load_more_timeline do |tl_slug, source, domain, path, token, params|
    notice "worldon: worldon_load_more_timeline #{tl_slug} #{source} #{domain} #{path} #{token} #{params}"
    resp = pm::API.call(:get, domain, path, token, **params)
    next unless resp

    messages = pm::Status.build(domain, resp.value)
    Plugin.call(:extract_load_more_messages, tl_slug, source, messages)
  end

  on_worldon_load_more_public_timeline do |tl_slug, source, oldest|
    notice "worldon: worldon_load_more_public_timeline #{tl_slug} #{source} #{oldest}"
    domain, type = pm::Instance.datasource_slug_inv(source)
    domain = oldest.account.domain
    status_id = nil
    if oldest.account.domain == domain
      status_id = File.basename(oldest.uri.path)
    else
      worlds, = Plugin.filtering(:worldon_worlds, nil)
      world = worlds.select { |w| w.domain == domain }
      next if world.nil?
      status_id = pm::API.get_local_status_id(world, oldest)
    end
    next if status_id.nil? # oldestがそのドメインでの発言ではなかったFTLは（インスタンスローカルなIDが取得できないため）遡れない

    params = { limit: 40, max_id: status_id }
    path_base = '/api/v1/timelines/'
    case type
    when :federated
      path = path_base + 'public'
    when :federated_media
      path = path_base + 'public'
      params[:only_media] = 1
    when :local
      path = path_base + 'public'
      params[:local] = 1
    when :local_media
      path = path_base + 'public'
      params[:local] = 1
      params[:only_media] = 1
    end

    Plugin.call(:worldon_load_more_timeline, tl_slug, source, domain, path, nil, params)
  end

  on_worldon_load_more_auth_timeline do |tl_slug, source, oldest|
    notice "worldon: worldon_load_more_auth_timeline #{tl_slug} #{source} #{oldest}"
    acct, type, n = pm::World.datasource_slug_inv(source)
    worlds, = Plugin.filtering(:worldon_worlds, nil)
    world = worlds.select {|w| w.account.acct == acct }.first
    next if world.nil?
    status_id = pm::API.get_local_status_id(world, oldest)
    next if status_id.nil?

    params = { limit: 40, max_id: status_id }
    path_base = '/api/v1/timelines/'
    case type
    when :list
      path = path_base + 'home'
    else
      path = path_base + type.to_s
    end

    Plugin.call(:worldon_load_more_timeline, tl_slug, source, world.domain, path, world.access_token, params)
  end

  on_worldon_appear_toots do |statuses|
    Plugin.call(:extract_receive_message, :worldon_appear_toots, statuses)
  end

  followings_updater = Proc.new do
    activity(:system, "自分のプロフィールやフォロー関係を取得しています...")
    Plugin.filtering(:worldon_worlds, nil).first.to_a.each do |world|
      world.update_account
      world.blocks!
      world.followings(cache: false).next do |followings|
        activity(:system, "自分のプロフィールやフォロー関係の取得が完了しました(#{world.account.acct})")
      end
      Plugin.call(:world_modify, world)
    end

    Reserver.new(10 * HYDE, &followings_updater) # 26分ごとにプロフィールとフォロー一覧を更新する
  end

  # 起動時
  Delayer.new {
    followings_updater.call
  }


  # world系

  defevent :worldon_worlds, prototype: [NilClass]

  # すべてのworldon worldを返す
  filter_worldon_worlds do
    [Enumerator.new{|y|
      Plugin.filtering(:worlds, y)
    }.select{|world|
      world.class.slug == :worldon
    }.to_a]
  end

  defevent :worldon_current, prototype: [NilClass]

  # world_currentがworldonならそれを、そうでなければ適当に探す。
  filter_worldon_current do
    world, = Plugin.filtering(:world_current, nil)
    unless [:worldon, :portal].include?(world.class.slug)
      worlds, = Plugin.filtering(:worldon_worlds, nil)
      world = worlds.first
    end
    [world]
  end

  on_userconfig_modify do |key, value|
    if [:worldon_enable_streaming, :extract_tabs].include?(key)
      Plugin.call(:worldon_restart_all_streams)
    end
  end

  # 別プラグインからサーバーを追加してストリームを開始する例
  # domain = 'friends.nico'
  # instance, = Plugin.filtering(:worldon_add_instance, domain)
  # Plugin.call(:worldon_restart_instance_stream, instance.domain) if instance
  filter_worldon_add_instance do |domain|
    [pm::Instance.add(domain)]
  end

  # サーバー編集
  on_worldon_update_instance do |domain|
    Thread.new {
      instance = pm::Instance.load(domain)
      next if instance.nil? # 既存にない

      Plugin.call(:worldon_restart_instance_stream, domain)
    }
  end

  # サーバー削除
  on_worldon_delete_instance do |domain|
    Plugin.call(:worldon_remove_instance_stream, domain)
    if UserConfig[:worldon_instances].has_key?(domain)
      config = UserConfig[:worldon_instances].dup
      config.delete(domain)
      UserConfig[:worldon_instances] = config
    end
  end

  # world追加時用
  on_worldon_create_or_update_instance do |domain|
    Thread.new {
      instance = pm::Instance.load(domain)
      if instance.nil?
        instance, = Plugin.filtering(:worldon_add_instance, domain)
      end
      next if instance.nil? # 既存にない＆接続失敗

      Plugin.call(:worldon_restart_instance_stream, domain)
    }
  end

  # world追加
  on_world_create do |world|
    if world.class.slug == :worldon
      Delayer.new {
        Plugin.call(:worldon_create_or_update_instance, world.domain, true)
      }
    end
  end

  # world削除
  on_world_destroy do |world|
    if world.class.slug == :worldon
      Delayer.new {
        worlds = Plugin.filtering(:worldon_worlds, nil).first
        # 他のworldで使わなくなったものは削除してしまう。
        # filter_worldsから削除されるのはココと同様にon_world_destroyのタイミングらしいので、
        # この時点では削除済みである保証はなく、そのためworld.slugで判定する必要がある（はず）。
        unless worlds.any?{|w| w.slug != world.slug && w.domain != world.domain }
          Plugin.call(:worldon_delete_instance, world.domain)
        end
        Plugin.call(:worldon_remove_auth_stream, world)
      }
    end
  end

  # world作成
  world_setting(:worldon, _('Mastodon(Worldon)')) do
    error_msg = nil
    while true
      if error_msg.is_a? String
        label error_msg
      end
      input 'サーバーのドメイン', :domain

      result = await_input
      domain = result[:domain]

      instance = pm::Instance.load(domain)
      if instance.nil?
        # 既存にないので追加
        instance, = Plugin.filtering(:worldon_add_instance, domain)
        if instance.nil?
          # 追加失敗
          error_msg = "#{domain} サーバーへの接続に失敗しました。やり直してください。"
          next
        end
      end

      break
    end

    error_msg = nil
    while true
      if error_msg.is_a? String
        label error_msg
      end
      label 'Webページにアクセスして表示された認証コードを入力して、次へボタンを押してください。'
      link instance.authorize_url
      puts instance.authorize_url # ブラウザで開けない時のため
      $stdout.flush
      input '認証コード', :authorization_code
      if error_msg.is_a? String
        input 'アクセストークンがあれば入力してください', :access_token
      end
      result = await_input
      if result[:authorization_code]
        result[:authorization_code].strip!
      end
      if result[:access_token]
        result[:access_token].strip!
      end

      if ((result[:authorization_code].nil? || result[:authorization_code].empty?) && (result[:access_token].nil? || result[:access_token].empty?))
        error_msg = "認証コードを入力してください"
        next
      end

      break
    end

    if result[:authorization_code]
      resp = pm::API.call(:post, domain, '/oauth/token',
                                       client_id: instance.client_key,
                                       client_secret: instance.client_secret,
                                       grant_type: 'authorization_code',
                                       redirect_uri: 'urn:ietf:wg:oauth:2.0:oob',
                                       code: result[:authorization_code]
                                      )
      if resp.nil? || resp.value.has_key?(:error)
        label "認証に失敗しました#{resp && resp[:error] ? "：#{resp[:error]}" : ''}"
        await_input
        raise (resp.nil? ? 'error has occurred at /oauth/token' : resp[:error])
      end
      token = resp[:access_token]
    else
      token = result[:access_token]
    end

    resp = pm::API.call(:get, domain, '/api/v1/accounts/verify_credentials', token)
    if resp.nil? || resp.value.has_key?(:error)
      label "アカウント情報の取得に失敗しました#{resp && resp[:error] ? "：#{resp[:error]}" : ''}"
      raise (resp.nil? ? 'error has occurred at verify_credentials' : resp[:error])
    end

    screen_name = resp[:acct] + '@' + domain
    resp[:acct] = screen_name
    account = pm::Account.new(resp.value)
    world = pm::World.new(
      id: screen_name,
      slug: :"worldon:#{screen_name}",
      domain: domain,
      access_token: token,
      account: account
    )
    world.update_mutes!

    label '認証に成功しました。このアカウントを追加しますか？'
    label('アカウント名：' + screen_name)
    label('ユーザー名：' + resp[:display_name])
    world
  end
end
