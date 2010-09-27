
require 'open-uri'
require 'cinch'
require "date"

class FancyLogger
  include Cinch::Plugin

  listen_to :channel, :join, :me, :part, :quit, {:use_prefix => false}

  def log_message(logfile, msg)
    if msg.user.nick
      logfile.puts "[#{Time.now}] #{msg.user.nick}: #{msg.message}"
    else
      logfile.puts "[#{Time.now}]: #{msg.message}"
    end
  end

  def listen(m)
    @last_logtime ||= Time.now
    @logged_messages ||= []
    @logged_messages << m

    # every 60 seconds
    if (Time.now - @last_logtime) > 60
      logfile = "#fancy_#{Date.today}.log"
      $stderr.puts "Writing #{@logged_messages.size} messages to #{logfile}."

      File.open(logfile, "a") do |f|
        @logged_messages.each do |msg|
          log_message f, msg
        end
      end
      @last_logtime = Time.now
      @logged_messages.clear
    end
  end
end

class Seen < Struct.new(:who, :where, :what, :time)
  def to_s
    "[#{time.asctime}] #{who} was seen in #{where} saying #{what}"
  end
end

#######################
# The actual irc bot: #
#######################

bot = Cinch::Bot.new do
  configure do |c|
    c.server   = "irc.freenode.org"
    c.channels = ["#fancy_bot_test"]
    c.nick = "fancy_bot"
    c.plugins.plugins = [FancyLogger]

    @seen_users = {}
    @start_time = Time.now
  end

  helpers do
    def shorten(url)
      url = open("http://tinyurl.com/api-create.php?url=#{URI.escape(url)}").read
      url == "Error" ? nil : url
    rescue OpenURI::HTTPError
      nil
    end
  end

  # Message handlers

  # Only log channel messages for !seen
  on :channel do |m|
    @seen_users[m.user.nick] = Seen.new(m.user.nick, m.channel, m.message, Time.new)
  end

  # Display !seen user info
  on :channel, /^!seen (.+)/ do |m, nick|
    if nick == bot.nick
      m.reply "That's me!"
    elsif nick == m.user.nick
      m.reply "That's you!"
    elsif @seen_users.key?(nick)
      m.reply @seen_users[nick].to_s
    else
      m.reply "Sorry, I haven't seen #{nick}"
    end
  end

  # Display shortened URLs (via tinyurl.com)
  on :channel, /^!shorten (.+)$/ do |m, url|
    urls = URI.extract(url, "http")

    unless urls.empty?
      short_urls = urls.map {|url| shorten(url) }.compact

      unless short_urls.empty?
        m.reply short_urls.join(", ")
      end
    end
  end

  # Display uptime of bot in channel
  on :message, "!uptime" do |m|
    m.reply "I'm running since #{@start_time}, which is #{Time.at(Time.now - @start_time).gmtime.strftime('%R:%S')}"
  end

  on :message, "!info" do |m|
    m.reply "This if FancyBot v0.1 running @ irc.fancy-lang.org"
  end
end

trap("INT") do
  puts "Bot is quitting"
  exit
end

bot.start
