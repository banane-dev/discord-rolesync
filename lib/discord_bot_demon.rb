class Demon::DiscordBot < ::Demon::Base
  def self.prefix
    "discord_bot"
  end

  private

  def suppress_stdout
    false
  end

  def suppress_stderr
    false
  end

  def bot_not_ready!
    Discourse.redis.set("discord_bot:ready", 0)
  end

  def bot_ready!
    Discourse.redis.set("discord_bot:ready", 1)
  end

  def bot_ready?
    return true if Discourse.redis.get("discord_bot:ready") == "1"
    return false
  end

  def sync_command
    Discourse.redis.get("discord_bot:sync")
  end

  def handle_interrups
    at_exit { @bot.stop unless @bot.nil? }
    trap('INT')  { shutdown }
    trap('TERM') { shutdown }
    trap('HUP')  { shutdown }
  end
  #conditions
  def no_token
    SiteSetting.discord_rolesync_token.empty? ||
      SiteSetting.discord_rolesync_token.nil?
  end

  def already_running
    !@bot.nil? && !@bot.gateway.nil? && @bot.gateway.open?
  end

  #/conditions

  def setup_bot_events
    #member sync on discord member update event
    @bot.member_update() do |event|
      uaa = UserAssociatedAccount.where(provider_uid: event.user.id,
        provider_name: "discord").includes(:user)
      if uaa.any?
        user = uaa.first.user
        groups_with_discord_role_id = GroupCustomField.where(name: "discord_role_id").where.not(value: "").includes(:group)
        groups_with_discord_role_id.each{ |gwdri|
            if event.roles.include?(gwdri.value)
              gwdri.group.add(user)
            else
              gwdri.group.remove(user)
            end
          }
      end
    end
      #ready event
      @bot.ready {
        Discourse.redis.set("discord_bot:current_action", "")
        bot_ready!
      }

      #disconnect event
      @bot.disconnected {
        bot_not_ready!
      }
  end

  def shutdown
    @running = false
    puts "[DiscordRolesync] discord bot demon shutting down "
    exit 0
  end

  def start_discord_bot
    return if no_token || already_running
    Discourse.redis.set("discord_bot:current_action", " currently starting ...")
    puts "[DiscordRolesync] discord bot started!"
    @bot = Discordrb::Bot.new(token: SiteSetting.discord_rolesync_token,
                                      intents: %i[servers server_members])
    setup_bot_events
    @bot.run(true)
  end

  def stop_discord_bot
    return unless already_running
    Discourse.redis.set("discord_bot:current_action", "")
    puts "[DiscordRolesync] discord bot stoped!"
    bot_not_ready!
    @bot.stop unless @bot.nil?
  end

  def sync_discord_roles
    return unless bot_ready?
    puts "[DiscordRolesync] discord bot syncing!"
    Discourse.redis.set("discord_bot:current_action", " currently syncing ...")


    groups_with_discord_role_id = GroupCustomField.where(name: "discord_role_id").where.not(value: "").includes(:group)
    groups_with_discord_role_id.each{ |gwdri|
      discourse_group = gwdri.group
      role = @bot.servers[@bot.servers.keys.first].role(gwdri.value)
      if role
        discourse_members = discourse_group.users.includes(:user_associated_accounts).where('user_associated_accounts.provider_name = ?','discord').references(:user_associated_accounts)
        discourse_group.users.each{|u|
          #remove all members that do not have a discord account connected
          unless discourse_members.ids.include? (u.id)
            discourse_group.remove(u)
          end
        }
        #remove all members that do not have the specific discord role
        discourse_members.each{|m|
          unless role.members.include? (m.user_associated_accounts[0].provider_uid)
            discourse_group.remove(m)
          end
        }
        #add all users that have the discord role to the discourse group
        discord_members = UserAssociatedAccount.where(provider_uid: role.members.map{|m|m.id},provider_name: "discord").includes(:user)
        discord_members.each{|m|
          discourse_group.add(m.user)
        }
      end
    }

    Discourse.redis.set("discord_bot:current_action", "")
    Discourse.redis.del("discord_bot:sync")
  end

  def after_fork
    puts "[DiscordRolesync] Loading DiscordRolesync in process id #{Process.pid}"
    handle_interrups
    @bot = nil
    @running = true
    bot_not_ready!

    while @running
      start_discord_bot if SiteSetting.discord_rolesync_bot_on
      stop_discord_bot unless SiteSetting.discord_rolesync_bot_on
      sync_discord_roles if SiteSetting.discord_rolesync_bot_on
      sleep 1
    end

    exit 0
  rescue => e
    STDERR.puts e.message
    STDERR.puts e.backtrace.join("\n")
    exit 1
  end

end
