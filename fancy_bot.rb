require 'open-uri'
require 'cinch'
require "date"
require "timeout"
require "open3"

FANCY_DIR = ARGV[0]
FANCY_CMD = "#{FANCY_DIR}/bin/fancy -I #{FANCY_DIR}"
LOGDIR = ARGV[1] ? ARGV[1] : "."

class Cinch::Bot
  attr_reader :plugins # hack to allow access to plugins from outside
end

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

  def logfile
    "#{LOGDIR}/#fancy_#{Date.today}.txt"
  end

  def log_messages
    if @logged_messages
      File.open(logfile, "a") do |f|
        @logged_messages.each do |msg|
          log_message f, msg
        end
        @logged_messages.clear
      end
    end
  end

  def listen(m)
    @last_logtime ||= Time.now
    @logged_messages ||= []
    @logged_messages << m

    # every 60 seconds
    if (Time.now - @last_logtime) > 60
      $stderr.puts "Writing #{@logged_messages.size} messages to #{logfile}."
      log_messages
      @last_logtime = Time.now
    end
  end

  def shutdown
    log_messages
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
    c.channels = ["#fancy"]
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

    # fetch latest revision from github
    def fetch_latest_revision(m)
      Open3.popen3("cd #{FANCY_DIR} && git pull origin master") do |stdin, stdout, stderr|
        err_lines = stderr.readlines
        if err_lines.size > 0
          # only print error lines if we're not dealing with an
          # already-up-to-date-message.
          unless err_lines.all?{|l| l !~ /Already up-to-date./}
            m.reply "Got error while trying to update from repository:"
            err_lines.each do |l|
              m.reply l.chomp
            end
            m.reply "Won't/Can't build or run tests."
            return false # done since error
          end
        end
      end
      return true
    end

    # sends error messages to channel, ignoring any warnings etc that
    # aren't real error messages
    def send_errors(m, errors, cmd)
      # ignore warnings and make output lines
      errors.reject! do |e|
        e =~ /make(.+)?:/ ||
        e =~ /warning|warnung|In function/i ||
        e =~ /fancy.y: Konflikte:/
      end

      size = errors.size
      if size > 5
        errors = errors[0..4]
      end

      if size > 0
        m.reply "Got #{size} errors during '#{cmd}':"
      end

      errors.each do |l|
        m.reply l.chomp
      end

      if size > 5
        m.reply "[...] (#{size - 5} more error lines were omitted)"
      end

      return size
    end

    # runs a given comand in FANCY_DIR and outputs any resulting error
    # messages
    def do_cmd(m, cmd)
      Open3.popen3("cd #{FANCY_DIR} && #{cmd}") do |stdin, stdout, stderr|
        errors = stderr.readlines
        if errors.size > 0
          real_errors = send_errors(m, errors, cmd)
          yield if real_errors > 0
        end
      end
    end

    # try to build fancy source
    def try_build(m)
      do_cmd(m, "./configure"){ return false }
      do_cmd(m, "make clean"){ return false }
      do_cmd(m, "make"){ return false }
      return true
    end

    # try to run FancySpecs
    def run_tests(m)
      IO.popen("cd #{FANCY_DIR} && make test", "r") do |o|
        lines = o.readlines
        failed = lines.select{|l| l =~ /FAILED:/}
        failed.each do |failed|
          m.reply failed.chomp
        end
        m.reply "=> #{failed.size} failed tests!"
      end
    end

    def do_update_build_test(m)
      m.reply "Getting latest changes & trying to run tests."
      return unless fetch_latest_revision m
      return unless try_build m
      run_tests m
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

  on :message, /^!(info|help) (.+)$/ do |m, foo, command_name|
    case command_name
    when "!seen"
      m.reply "!seen <nickname> : Displays information on when <nickname> was last seen."
    when "!uptime"
      m.reply "!uptime : Displays uptime information for FancyBot."
    when "!shorten"
      m.reply "!shorten <url> [<urls>] : Displays a shorted version of any given amount of urls (using tinyurl.com)."
    when /!(info|help)/
      m.reply "!info/!help [<command>]: Displays help text for <command>. If <command> is ommitted, displays general help text."
    when "!"
      m.reply "! <code> : Evaluates the <code> given (expects it to be Fancy code) and displays any output from evaluation."
      m.reply "! <code> : Maximum timeout for any computation is 5 seconds and only up to 5 lines will be displayed here (seperated by ';' instead of a newline)."
    else
      m.reply "Unknown command: #{command_name}."
    end
  end

  on :message, /^!(info|help)$/ do |m|
    m.reply "This is FancyBot v0.2 running @ irc.fancy-lang.org"
    m.reply "Possible commands are: !seen <nick>, !uptime, !shorten <url> [<urls>], !info, !help, ! <code>"
  end

  on :message, /^! (.+)$/ do |m, cmd|
    begin
      Timeout::timeout(5) do
        IO.popen("#{FANCY_CMD} -e \"File = nil; Directory = nil; System = nil; #{cmd.gsub(/\"/, "\\\"")}\"", "r") do |o|
          lines = o.readlines
          if lines.size <= 5
            m.reply "=> #{lines.map(&:chomp).join("; ")}"
          else
            m.reply "=> #{lines[0..4].map(&:chomp).join("; ")} [...]"
          end
        end
      end
    rescue Timeout::Error
      m.reply "=> Your computation took to long! Timeout is set to 5 seconds."
    end
  end

  on :message, /^fancy:/ do |m|
    if m.user.nick == "fancy_gh"
      do_update_build_test m
    end
  end
end

def bot_shutdown
  puts "Bot is quitting"
  bot.plugins.each do |p|
    p.shutdown
  end
  exit
end

trap("INT") do
  bot_shutdown
end

trap("KILL") do
  bot_shutdown
end

bot.start
