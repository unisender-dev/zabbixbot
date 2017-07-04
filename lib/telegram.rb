class TelegramBot
  def initialize(token, bot_owner, zbx_klass)
    @token = token
    @bot_owner = bot_owner
    @zbx = zbx_klass
    @duties = {}
    begin
      if File.exists?(File.dirname($0) + '/duties.json')
        @duties = JSON.parse(File.read(File.dirname($0) + '/duties.json'))
        @duties = {} unless @duties.kind_of?(Hash)
        @duties.each_value do |d|
          d.keys.each do |dk|
            if dk != dk.to_sym
              d[dk.to_sym] = d[dk]
              d.delete(dk)
            end
          end
        end
      end
    rescue
    end
    unless @duties.has_key?(@bot_owner)
      @duties[@bot_owner] = {
          chat: nil,
          notify: 6
      }
    end
    @requests = Queue.new
    begin
      if File.exists?(File.dirname($0) + '/requests_queue.json')
        data = JSON.parse(File.read(File.dirname($0) + '/requests_queue.json'))
        data.each do |d|
          d.keys.each do |dk|
            if dk != dk.to_sym
              d[dk.to_sym] = d[dk]
              d.delete(dk)
            end
          end
          @requests.push d
        end
        File.unlink(File.dirname($0) + '/requests_queue.json')
      end
    rescue
    end
    @messages = Queue.new
    begin
      if File.exists?(File.dirname($0) + '/messages_queue.json')
        data = JSON.parse(File.read(File.dirname($0) + '/messages_queue.json'))
        data.each do |d|
          d.keys.each do |dk|
            if dk != dk.to_sym
              d[dk.to_sym] = d[dk]
              d.delete(dk)
            end
          end
          @messages.push d
        end
        File.unlink(File.dirname($0) + '/messages_queue.json')
      end
    rescue
    end
    @reader = Thread.new {reader_thread}
    @writer = Thread.new {writer_thread}
    @processor = Thread.new {processor_thread}
  end

  def reader_thread
    begin
      Telegram::Bot::Client.run(@token) do |bot|
        loop do
          break if Thread.current.thread_variable?('stop') && Thread.current.thread_variable_get('stop') === true
          bot.listen do |msg|
            if !msg.from.username.empty? && @duties.keys.include?(msg.from.username)
              @requests.push({
                                 from: msg.from.username,
                                 chat: msg.chat.id,
                                 id: msg.message_id,
                                 text: msg.text
                             })
              @duties[msg.from.username][:chat] = msg.chat.id
            else
              bot.api.send_message(
                  chat_id: msg.chat.id,
                  parse_mode: 'HTML',
                  text: "You are not allowed to access this bot.\nPlease contact my boss: @#{@bot_owner}"
              )
            end
          end
          sleep 0.1
        end
      end
    rescue => e
      puts "[#{e.class}] #{e.message}"
      puts e.backtrace
      retry
    end
  end

  def writer_thread
    begin
      Telegram::Bot::Client.run(@token) do |bot|
        @duties.each_pair do |u, d|
          if d[:chat]
            bot.api.send_message(
                chat_id: d[:chat],
                text: "I'm online on #{`hostname`.chomp}."
            )
          end
        end
        loop do
          break if Thread.current.thread_variable?('stop') && Thread.current.thread_variable_get('stop') === true
          until @messages.empty?
            m = @messages.pop
            msgs = [""]
            until m[:text].empty?
              if (m[:text].first.length + msgs.last.length) <= 2048
                if m[:text].first.length > 256
                  longline = m[:text].delete_at(0)
                  longline.scan(/.{1,256}/).reverse.each do |l|
                    m[:text].insert(0, l)
                  end
                  next
                end
                msgs[msgs.length - 1] += "\n" unless msgs.last.empty?
                msgs[msgs.length - 1] += m[:text].delete_at(0)
              else
                msgs << ""
              end
            end
            msgs.each do |text|
              if m[:chat]
                bot.api.send_message(
                    chat_id: m[:chat],
                    text: text,
                    parse_mode: 'HTML'
                )
              end
            end
          end
          sleep 0.1
        end
        @duties.each_pair do |u, d|
          if d[:chat]
            bot.api.send_message(
                chat_id: d[:chat],
                text: "I'm going offline (on #{`hostname`.chomp}). Bye!"
            )
          end
        end
      end
    rescue => e
      puts "[#{e.class}] #{e.message}"
      puts e.backtrace
      retry
    end
  end

  def processor_thread
    begin
      loop do
        break if Thread.current.thread_variable?('stop') && Thread.current.thread_variable_get('stop') === true
        until @requests.empty?
          r = @requests.pop
          case r[:text]
            when /^\//
              # command
              params = r[:text].split(/[\s_]+/)
              command = params.delete_at(0).gsub(/^\//, '')
              if self.respond_to?("command_#{command}".to_sym)
                self.send("command_#{command}".to_sym, r, params.join(' '))
              else
                @messages.push(
                    chat: r[:chat],
                    text: ["Command <b>#{command}</b> not found!"]
                )
                self.command_help(r, '')
              end
            else
              # message to all
              command_messageall(r, r[:text])
          end
        end
        sleep 0.1
      end
    rescue => e
      puts "[#{e.class}] #{e.message}"
      puts e.backtrace
      retry
    end
  end

  def stop
    @processor.thread_variable_set('stop', true)
    @processor.join
    @writer.thread_variable_set('stop', true)
    @writer.join
    @reader.thread_variable_set('stop', true)
    5.times do
      sleep 1 unless @reader.stop?
    end
    File.open(File.dirname($0) + '/duties.json', 'w') do |f|
      f.write(JSON.pretty_generate(@duties))
    end
    File.open(File.dirname($0) + '/requests_queue.json', 'w') do |f|
      result = []
      until @requests.empty?
        result << @requests.pop
      end
      f.write(JSON.pretty_generate(result))
    end
    File.open(File.dirname($0) + '/messages_queue.json', 'w') do |f|
      result = []
      until @messages.empty?
        result << @messages.pop
      end
      f.write(JSON.pretty_generate(result))
    end
  end

  def notify(changes = {})
    @duties.each_value do |d|
      msg = []
      changes.each_pair do |priority, text|
        if priority >= d[:notify]
          text.each do |line|
            msg << line
          end
        end
      end
      unless msg.empty?
        @messages.push(
            chat: d[:chat],
            text: msg
        )
      end
    end
  end

  def command_help(r, _)
    @messages.push(
        chat: r[:chat],
        text: [
            '<b>Available commands:</b>',
            '/start, /help - show this help',
            '/notify &lt;info|warn|avg|high|disaster|off&gt; - change notification level',
            '/add &lt;username&gt; - allow username to access this bot',
            '/remove &lt;username&gt; - disallow username to access this bot',
            '/users - show users and their notification level',
            '/status - show unacknowledged problems',
            '/statusall, /statusfull - show all problems',
            '&lt;message&gt; - forward message to all users with enabled notifications'
        ]
    )
  end
  alias command_start command_help

  def command_messageall(r, text='')
    @duties.each_pair do |u, d|
      if u != r[:from]
        @messages.push(
            chat: d[:chat],
            text: ["From @<b>#{r[:from]}</b>:\n" + text]
        )
        @messages.push(
            chat: r[:chat],
            text: ["Your message was sent to @<b>#{u}</b>."]
        )
      end
    end
  end

  def command_notify(r, text='')
    params = text.split(/\s+/)
    level = params.delete_at(0)
    user = r[:from]
    if !params.empty? && @duties.has_key?(params.first)
      user = params.first
    end
    text = "Notification level of user <b>#{user}</b> changed to <b>#{level}</b>"
    case level
      when 'info'
        @duties[user][:notify] = 1
      when 'warn'
        @duties[user][:notify] = 2
      when 'avg'
        @duties[user][:notify] = 3
      when 'high'
        @duties[user][:notify] = 4
      when 'disaster'
        @duties[user][:notify] = 5
      when 'off'
        @duties[user][:notify] = 6
      else
        text = "Can't change notification level of user @<b>#{user}</b>."
    end
    @messages.push(
        chat: r[:chat],
        text: [text]
    )
    File.open(File.dirname($0) + '/duties.json', 'w') do |f|
      f.write(JSON.pretty_generate(@duties))
    end
  end

  def command_add(r, text='')
    if text.empty?
      @messages.push(
          chat: r[:chat],
          text: ['Usage: /add &lt;username&gt;']
      )
      return false
    end
    if text =~ /^@/
      text.gsub!(/^@/, '')
    end
    if @duties.has_key?(text)
      @messages.push(
          chat: r[:chat],
          text: ["Username @<b>#{text}</b> already granted to access this bot."]
      )
      return false
    end
    @duties[text] = {
        chat: nil,
        notify: 6
    }
    @messages.push(
        chat: r[:chat],
        text: ["Username @<b>#{text}</b> granted to access this bot."]
    )
    File.open(File.dirname($0) + '/duties.json', 'w') do |f|
      f.write(JSON.pretty_generate(@duties))
    end
  end

  def command_remove(r, text='')
    if text.empty?
      @messages.push(
          chat: r[:chat],
          text: ['Usage: /remove &lt;username&gt;']
      )
      return false
    end
    if text =~ /^@/
      text.gsub!(/^@/, '')
    end
    unless @duties.has_key?(text)
      @messages.push(
          chat: r[:chat],
          text: ["Username @<b>#{text}</b> already removed from this bot."]
      )
      return false
    end
    @duties.delete(text)
    @messages.push(
        chat: r[:chat],
        text: ["Username @<b>#{text}</b> removed from this bot."]
    )
    File.open(File.dirname($0) + '/duties.json', 'w') do |f|
      f.write(JSON.pretty_generate(@duties))
    end
  end

  def command_users(r, _)
    result = ['Users with access:']
    @duties.each_pair do |u, d|
      level = case d[:notify]
                when 1
                  'INFO'
                when 2
                  'WARN'
                when 3
                  'AVG'
                when 4
                  'HIGH'
                when 5
                  'DISASTER'
                when 6
                  'OFF'
                else
                  'unknown'
              end
      result << "@<b>#{u}</b> with level <b>#{level}</b>#{(d[:chat] ? '' : ' (never chatted!)')}"
    end
    @messages.push(
        chat: r[:chat],
        text: result
    )
  end

  def command_status(r, _)
    unless @zbx
      @messages.push(
          chat: r[:chat],
          text: ['Could not connect to Zabbix worker!']
      )
      return false
    end
    text = ['Found unacknowledged events:']
    events = @zbx.get_status
    if events.empty?
      text << 'nothing found.'
    else
      events.each_value do |lines|
        lines.each do |line|
          text << line
        end
      end
    end
    @messages.push(
        chat: r[:chat],
        text: text
    )
  end

  def command_statusall(r, _)
    unless @zbx
      @messages.push(
          chat: r[:chat],
          text: ['Could not connect to Zabbix worker!']
      )
      return false
    end
    text = ['Found events:']
    events = @zbx.get_statusall
    if events.empty?
      text << 'nothing found.'
    else
      events.each_value do |lines|
        lines.each do |line|
          text << line
        end
      end
    end
    @messages.push(
        chat: r[:chat],
        text: text
    )
  end

  alias command_statusfull command_statusall

  def command_ack(r, text='')
    unless @zbx
      @messages.push(
          chat: r[:chat],
          text: ['Could not connect to Zabbix worker!']
      )
      return false
    end
    if @zbx.ack(text, "Acknowledged by #{r[:from]} (ZabbixBot)")
      @messages.push(
          chat: r[:chat],
          text: ['Event acknowledged!']
      )
    else
      @messages.push(
          chat: r[:chat],
          text: ['Could not connect acknowledge event!']
      )
    end
  end
end
