class Zabbix
  def initialize(opts = {})
    uri = opts.fetch(:uri, 'http://localhost/zabbix/api_jsonrpc.php')
    user = opts.fetch(:user, 'admin')
    pass = opts.fetch(:pass, 'admin')
    @client = ZabbixApi.connect(
        url: uri,
        user: user,
        password: pass
    )
    @events = {}
    begin
      if File.exists?(File.dirname($0) + '/events.json')
        @events = JSON.parse(File.read(File.dirname($0) + '/events.json'))
        @events.each_value do |d|
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
    @operations = Queue.new
    begin
      if File.exists?(File.dirname($0) + '/operations_queue.json')
        data = JSON.parse(File.read(File.dirname($0) + '/operations_queue.json'))
        data.each do |d|
          d.keys.each do |dk|
            if dk != dk.to_sym
              d[dk.to_sym] = d[dk]
              d.delete(dk)
            end
          end
          @operations.push d
        end
        File.unlink(File.dirname($0) + '/operations_queue.json')
      end
    rescue
    end
    @reader = Thread.new {reader_thread}
  end

  def reader_thread
    begin
      loop do
        break if Thread.current.thread_variable?('stop') && Thread.current.thread_variable_get('stop') === true
        # get problems
        events = @client.query(
            method: 'problem.get',
            params: {
                sortfield: :eventid,
                source: 0
            }
        ).map {|p| p['eventid']}.sort.uniq.compact
        # get events
        triggers = @client.query(
            method: 'event.get',
            params: {
                eventids: events,
                source: 0,
                selectRelatedObject: 1,
                select_acknowledges: 1
            }
        ).map {|e| [e['relatedObject']['triggerid'], [e['acknowledged'], e['clock'], e['eventid']]]}.to_h
        # get triggers
        data = @client.query(
            method: 'trigger.get',
            params: {
                output: :extend,
                triggerids: triggers.keys,
                monitored: 1,
                maintenance: 0,
                skipDepentent: 1,
                expandComment: 1,
                expandDescription: 1,
                selectHosts: 1
            }
        )
        # get hosts
        hosts = @client.query(
            method: 'host.get',
            params: {
                hostids: data.map {|d| d['hosts'].first['hostid']}.sort.uniq.compact
            }
        ).map {|h| [h['hostid'], h['host']]}.to_h
        # process changes
        data.each do |d|
          if @events[d['triggerid']]
            # update event
            if @events[d['triggerid']][:acknowledged] != case triggers[d['triggerid']][0]
                                                           when '1'
                                                             true
                                                           when '0'
                                                             false
                                                         end
              if @events[d['triggerid']][:acknowledged] === false
                @events[d['triggerid']][:acknowledged] = true
                @operations.push(
                    action: 'acknowledged',
                    event_key: d['triggerid']
                )
              end
            end
            @events[d['triggerid']][:message] = d['description']
            @events[d['triggerid']][:added] = Time.at(triggers[d['triggerid']][1].to_i).to_s
            @events[d['triggerid']][:eventid] = triggers[d['triggerid']][2]
          else
            # add event
            @events[d['triggerid']] = {
                message: d['description'],
                priority: d['priority'].to_i,
                acknowledged: false,
                added: Time.at(triggers[d['triggerid']][1].to_i).to_s,
                eventid: triggers[d['triggerid']][2],
                host: hosts.fetch(d['hosts'].first['hostid'], 'unknown')
            }
            @operations.push(
                action: 'added',
                event_key: d['triggerid']
            )
          end
        end
        # process removals
        @events.keys.each do |ek|
          unless triggers.keys.include?(ek)
            unless @events[ek][:waits_remove] === true
              @events[ek][:waits_remove] = true
              @operations.push(
                  action: 'removed',
                  event_key: ek
              )
            end
          end
        end
        File.open(File.dirname($0) + '/events.json', 'w') do |ef|
          ef.write(JSON.pretty_generate(@events))
        end
        sleep 5
      end
    rescue => e
      puts "[#{e.class}] #{e.message}"
      puts e.backtrace
      retry
    end
  end

  def stop
    @reader.thread_variable_set('stop', true)
    @reader.join
    File.open(File.dirname($0) + '/operations_queue.json', 'w') do |f|
      result = []
      until @operations.empty?
        result << @operations.pop
      end
      f.write(JSON.pretty_generate(result))
    end
  end

  def get_changes
    result = {}
    until @operations.empty?
      o = @operations.pop
      priority = @events[o[:event_key]][:priority]
      result[priority] ||= []
      case o[:action]
        when 'added'
          result[priority] << "[<b>#{text_priority(priority)}</b>] <i>#{@events[o[:event_key]][:host]}</i>: #{@events[o[:event_key]][:message]}"
        when 'removed'
          if @events[o[:event_key]][:waits_remove]
            result[priority] << "[OK] <i>#{@events[o[:event_key]][:host]}</i>: #{@events[o[:event_key]][:message]}"
            @events.delete(o[:event_key])
          end
        when 'acknowledged'
          result[priority] << "[ACK] <i>#{@events[o[:event_key]][:host]}</i>: #{@events[o[:event_key]][:message]}"
      end
    end
    result_sorted = {}
    result.keys.sort.reverse.each do |p|
      result_sorted[p] ||= []
      result_sorted[p] = result[p]
    end
    return result_sorted
  end

  def get_status
    result = {}
    @events.each_pair do |id, e|
      unless e[:acknowledged]
        priority = e[:priority]
        result[priority] ||= []
        result[priority] << "[<b>#{text_priority(priority)}</b>] <i>#{e[:host]}</i> #{e[:message]} <i>#{text_duration(e[:added])}</i> (/ack_#{id})"
      end
    end
    result_sorted = {}
    result.keys.sort.reverse.each do |p|
      result_sorted[p] ||= []
      result_sorted[p] = result[p]
    end
    return result_sorted
  end

  def get_statusall
    result = {}
    @events.each_pair do |id, e|
      priority = e[:priority]
      result[priority] ||= []
      if e[:acknowledged]
        result[priority] << "[#{text_priority(priority)}] <i>#{e[:host]}</i> #{e[:message]} <i>#{text_duration(e[:added])}</i>"
      else
        result[priority] << "[<b>#{text_priority(priority)}</b>] <i>#{e[:host]}</i> #{e[:message]} <i>#{text_duration(e[:added])}</i> (/ack_#{id})"
      end
    end
    result_sorted = {}
    result.keys.sort.reverse.each do |p|
      result_sorted[p] ||= []
      result_sorted[p] = result[p]
    end
    return result_sorted
  end

  def ack(id, text = 'Acknowledged by ZabbitBot')
    return false unless @events.has_key?(id)
    return false unless @events[id][:eventid]
    begin
      @client.query(
                 method: 'event.acknowledge',
                 params: {
                     eventids: @events[id][:eventid],
                     message: text,
                     action: 0
                 }
      )
      return true
    rescue
      return false
    end
  end

  def text_priority(level = 0)
    return case level
             when 0
               'N/A'
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
           end
  end

  def text_duration(started = Time.now.to_s)
    weeks = 0
    days = 0
    hours = 0
    minutes = 0
    seconds = 0
    duration = Time.now - Time.parse(started)
    while duration >= 604800
      weeks += 1
      duration -= 604800
    end
    while duration >= 86400
      days += 1
      duration -= 86400
    end
    while duration >= 86400
      days += 1
      duration -= 86400
    end
    while duration >= 3600
      hours += 1
      duration -= 3600
    end
    while duration >= 60
      minutes += 1
      duration -= 60
    end
    seconds = duration.to_i
    text = ''
    text += "#{weeks}w" if weeks > 0
    text += "#{days}d" if days > 0
    text += "#{hours}h" if hours > 0
    text += "#{minutes}m" if minutes > 0
    text += "#{seconds}s"
    return text
  end
end
