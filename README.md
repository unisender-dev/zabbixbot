# ZabbixBot

This is Telegram bot for receiving and processing Zabbix notifications.

## Installation

* Install ruby

`apt-get install ruby ruby-dev`

* Install bundler

`gem install bundle`

* Clone repo

`git clone https://github.com/unisender-dev/zabbixbot.git /opt/zabbixbot`

* Create settings file `/etc/default/zabbixbot`

```
# Telegram API token (request it from https://telegram.me/botfather)
BOT_TOKEN=XXXXXXXXX:YYYYYYYYYYYY-ZZZZZZZZZZZZZZZZZZZZZZ

# Enter your Telegram username here to get access to bot. 
BOT_OWNER=yourtelegramusername

# Zabbix connection parameters

ZBX_URI=http://localhost/api_jsonrpc.php
ZBX_USER=admin
ZBX_PASS=admin

```

* Create systemd unit `/etc/systemd/system/zabbixbot.service`

```
[Unit]
Description=Zabbix bot
Wants=syslog.service
After=network.target syslog.service

[Install]
WantedBy=multi-user.target

[Service]
WorkingDirectory=/opt/zabbixbot
EnvironmentFile=/etc/default/zabbixbot
ExecStartPre=/bin/sh -c 'bundle install'
ExecStart=/bin/sh -c 'bundle exec ./bot.rb'
TimeoutSec=30s
RestartSec=5s
Restart=always
```

* Enable and start service

```
systemctl daemon-reload
systemctl start zabbixbot
systemctl enable zabbixbot
```

## Usage

Just find your bot in Telegram and write `/start` to him.
