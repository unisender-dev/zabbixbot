#!/usr/bin/env ruby

require 'bundler'
Bundler.require
require 'thread'
load 'lib/telegram.rb'
load 'lib/zabbix.rb'

bot_owner = ENV.fetch('BOT_OWNER', 'macrosonline')
bot_token = ENV.fetch('BOT_TOKEN', '309310703:AAG0WLGPKypfNKQaWwe7oA5nZ4txeQxXAZU')
zbx_uri = ENV.fetch('ZBX_URI', 'http://localhost/zabbix/api_jsonrpc.php')
zbx_user = ENV.fetch('ZBX_USER', 'admin')
zbx_pass = ENV.fetch('ZBX_PASS', 'admin')

@zbx = Zabbix.new(
    uri: zbx_uri,
    user: zbx_user,
    pass: zbx_pass
)

@tlg = TelegramBot.new(bot_token, bot_owner, @zbx)

$stop = false
trap('INT') {$stop = true}
trap('TERM') {$stop = true}
loop do
  break if $stop
  sleep 1
  @tlg.notify(@zbx.get_changes)
end

@tlg.stop
@zbx.stop
