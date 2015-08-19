require 'rubygems'
require 'twitter'
require 'pp'
require 'active_support/inflector'
require 'active_support/core_ext/object'
require 'active_support/json'
require 'ostruct'
require 'flickraw'
require 'instagram'
require 'csv'
require 'googleauth'
require 'google_drive'
require 'trollop'
require 'yaml'

OPTS = Trollop::options do
    banner <<-EOS
Harvest recent tagged photo metadata from social media services and store the
data in local CSV files or a Google Spreadsheet. Note that this only harvests
*recent* photos, not *all* photos available through the APIs, so it's designed
to be run regularly, depending on how much usage your tags get.

You MUST provide at least one tag and one API key and/or secret for
this script to do anything. It will write to local CSV files by default.

Since this is pretty configuration-heavy, you can also specify all the API
keys and secrets in a YAML file specified by the --config option.

Usage:
  # Save info about Instagram photos for two tags in a local CSV file
  bundle exec ruby fireslurp.rb --instagram-key=xxx morganfire01 morganfire02

  # Save info about Twitter photos for two tags to a Google Spreadsheet
  bundle exec ruby fireslurp.rb \
    --twitter-key=xxx \
    --twitter-secret=yyy \
    --google-application-credentials=/path/to/your/key.json \
    --google-spreadsheet-id=1234abcd \
    morganfire01 morganfire02

  # Save info about photos for two tags using config from a YAML file
  bundle exec ruby fireslurp.rb -c fireslurp.yaml morganfire01 morganfire02

where [options] are:
EOS
  opt :debug, "Print debug statements, don't save data", :type => :boolean, :short => "-d"
  opt :auto_approve, "
    For a Google Spreadsheet, automatically approve all contributions by
    filling the usable_tag column with the tag the contributor used
  ".strip, :type => :boolean
  opt :config, "Path to YAML configuration file", :type => :string, :short => "-c"
  opt :twitter_key, "Twitter API key", :type => :string
  opt :twitter_secret, "Twitter API secret", :type => :string
  opt :flickr_key, "Flickr API key", :type => :string
  opt :flickr_secret, "Flickr API secret", :type => :string
  opt :instagram_key, "Instagram API key", :type => :string
  opt :google_application_credentials, "Path to Google JSON key", type: :string
  opt :google_spreadsheet_id, "
    Write data to a Google Spreadsheet instead of CSV. The value should be the
    Google Spreadhseet ID. If it's blank and the flag is used, the script will
    look for an internal variable.
  ".strip, :type => :string, :short => '-g'
end

config = if OPTS[:config] && File.exists?(OPTS[:config])
  YAML.load_file(OPTS[:config])
else
  {}
end

## CONFIG ###############################################
TAGS                            = ARGV
TWITTER_KEY                     = OPTS[:twitter_key]                      || config['twitter_key']
TWITTER_SECRET                  = OPTS[:twitter_secret]                   || config['twitter_secret']
FLICKR_KEY                      = OPTS[:flickr_key]                       || config['flickr_key']
FLICKR_SECRET                   = OPTS[:flickr_secret]                    || config['flickr_secret']
INSTAGRAM_KEY                   = OPTS[:instagram_key]                    || config['instagram_key']
GOOGLE_APPLICATION_CREDENTIALS  = OPTS[:google_application_credentials]   || config['google_application_credentials']
GOOGLE_SPREADSHEET_ID           = OPTS[:google_spreadsheet_id]            || config['google_spreadsheet_id']
AUTO_APPROVE                    = OPTS[:auto_approve]                     || config['auto_approve']
###############################################################

HEADERS = %w(provider tag datetime username usable_tag image_url url image_url_s image_url_m license title)

Trollop::die "you must specify at least one tag" if ARGV.empty?
Trollop::die "you must specify at least one API key" if [TWITTER_KEY, FLICKR_KEY, INSTAGRAM_KEY].compact.reject(&:blank?).blank?
num_google_opts = [GOOGLE_APPLICATION_CREDENTIALS, GOOGLE_SPREADSHEET_ID].compact.reject(&:blank?).size
if num_google_opts > 0 && num_google_opts < 2
  Trollop::die "you must specify a Google application credentials and spreadsheet ID if you specify any of those options"
end

class TwitterProvider
  def self.method_missing(method, *args, &block)
    @@instance ||= self.new
    @@instance.send(method, *args, &block)
  end

  def search(q, &block)
    client.search("#{q} -rt", :result_type => "recent").each do |tweet|
      next unless tweet.media.first
      block.yield(photo_from_api_response(tweet))
    end
  end

  def client
    return @client if @client
    @client = Twitter::REST::Client.new do |config|
      config.consumer_key = TWITTER_KEY
      config.consumer_secret = TWITTER_SECRET
    end
  end

  def photo_from_api_response(tweet)
    return nil unless p = tweet.media.first
    max_size = if p.sizes[:large] then "large"
    elsif p.sizes[:medium] then "medium"
    elsif p.sizes[:small] then "small"
    end
    return nil if max_size.nil? # skip if there's no reasonable image url
    OpenStruct.new(
      :response => tweet,
      :image_url => "#{p.media_url}:#{max_size}",
      :image_url_m => "#{p.media_url}:medium",
      :image_url_s => "#{p.media_url}:small",
      :username => tweet.user.name,
      :url => tweet.url,
      :datetime => tweet.created_at,
      :title => tweet.text,
      :license => "all rights reserved"
    )
  end
end

class FlickrProvider
  def self.method_missing(method, *args, &block)
    @@instance ||= self.new
    @@instance.send(method, *args, &block)
  end

  def search(q, &block)
    client.photos.search(:tags => [q], :per_page => 500, :extras => 'url_o,url_l,url_m,url_c,owner_name,date_taken,license').each do |photo|
      block.yield(OpenStruct.new(
        :response => photo,
        :image_url => photo.to_hash["url_o"],
        :image_url_m => photo.to_hash["url_c"],
        :image_url_s => photo.to_hash["url_m"],
        :title => photo.title,
        :license => decode_license(photo.to_hash["license"]),
        :username => photo.ownername,
        :url => "http://flickr.com/photos/#{photo.owner}/#{photo.id}",
        :datetime => Time.parse(photo.datetaken)
      ))
    end
  end

  def decode_license(code)
    case code.to_i 
    when 1 then "CC BY-NC-SA"
    when 2 then "CC BY-NC"
    when 3 then "CC BY-NC-ND"
    when 4 then "CC BY"
    when 5 then "CC SA"
    when 6 then "CC ND"
    when 7 then "PD"
    when 8 then "United States Government Work"
    else "all rights reserved"
    end
  end

  def client
    if FlickRaw.api_key.nil?
      FlickRaw.api_key = FLICKR_KEY
      FlickRaw.shared_secret = FLICKR_SECRET
    end
    flickr
  end
end

class InstagramProvider
  def self.method_missing(method, *args, &block)
    @@instance ||= self.new
    @@instance.send(method, *args, &block)
  end

  def search(q, &block)
    client.tag_recent_media(q).each do |photo|
      block.yield(OpenStruct.new(
        :response => photo,
        :image_url => photo.images.standard_resolution.url,
        :image_url_m => photo.images.standard_resolution.url,
        :image_url_s => photo.images.low_resolution.url,
        :username => photo.user.username,
        :url => photo.link,
        :datetime => Time.at(photo.created_time.to_i),
        :title => photo.caption ? photo.caption.text : 'Untitled',
        :license => "all rights reserved"
      ))
    end
  rescue Instagram::BadRequest => e
    puts "Instagram request failed: #{e.message}"
    return
  end

  def client
    return @client if @client
    Instagram.configure do |config|
      config.client_id = INSTAGRAM_KEY
    end
    @client = Instagram
  end
end

def write_to_csv(providers, tags)
  now = Time.now
  path = "fireslurp-#{now.strftime('%Y-%m-%d')}-#{now.to_i}.csv"
  csv = CSV.open(path, 'w') unless OPTS[:debug]
  csv << HEADERS unless OPTS[:debug]
  providers.each do |provider|
    provider_name = provider.name.underscore.split('_').first.capitalize
    tags.each do |tag|
      provider.search(tag) do |photo|
        next unless photo
        puts "#{provider}\t#{tag}\t#{photo.datetime}\t#{photo.username}\t\t#{photo.image_url}\t#{photo.url}"
        unless OPTS[:debug]
          csv << [provider_name, tag, photo.datetime.iso8601, photo.username, 't', photo.image_url, photo.url]
        end
      end
    end
  end
  csv.close unless OPTS[:debug]
end

def google_access_token
  scopes =  [
    "https://www.googleapis.com/auth/drive",
    "https://spreadsheets.google.com/feeds/"
  ]
  auth = begin
    Google::Auth.get_application_default(scopes)
  rescue RuntimeError => e
    raise e unless e.message =~ /Could not load the default credentials/
    # Google JSON key was not specified as an ENV variable, so let's try to set it using the options
    ENV['GOOGLE_APPLICATION_CREDENTIALS'] = GOOGLE_APPLICATION_CREDENTIALS
    begin
      Google::Auth.get_application_default(scopes)
    rescue RuntimeError => e
      raise e unless e.message =~ /Could not load the default credentials/
      if ENV['GOOGLE_APPLICATION_CREDENTIALS'].nil?
        puts <<-EOT

          Could not find Google credentials or they're not working. Set
          ENV['GOOGLE_APPLICATION_CREDENTIALS'] to the path to your JSON key
          file, set google_application_credentials to the same in your config
          YAML, or pass in --google-application-
          credentials=/path/to/credentials.json

        EOT
      else
        puts "Google credentials at #{ENV['GOOGLE_APPLICATION_CREDENTIALS']} don't seem to be working."
      end
      exit(0)
    end
  end
  auth.fetch_access_token!
  auth.access_token
end

def write_to_google(providers, tags)
  session = begin
    GoogleDrive.login_with_oauth(google_access_token)
  rescue Faraday::SSLError
    # Sometimes Faraday barfs if it can't find its certs. This will force it to do so in OS X, at least.
    # https://github.com/google/google-api-ruby-client/issues/253#issuecomment-128747637
    cert_path = Gem.loaded_specs['google-api-client'].full_gem_path+'/lib/cacerts.pem'
    ENV['SSL_CERT_FILE'] = cert_path
    GoogleDrive.login_with_oauth(google_access_token)
  end

  ws = session.spreadsheet_by_key(GOOGLE_SPREADSHEET_ID).worksheets[0]
  if ws.rows[0].nil? || ws.rows[0].size == 0
    HEADERS.each_with_index do |header,i|
      ws[1,i+1] = header
    end
    ws.save unless OPTS[:debug]
  end
  urls = ws.rows.map{|r| r[HEADERS.index('url')]}
  providers.each do |provider|
    provider_name = provider.name.underscore.split('_').first.capitalize
    puts
    tags.each do |tag|
      provider.search(tag) do |photo|
        next unless photo
        puts [
          provider_name.ljust(10),
          tag.ljust(15),
          photo.datetime.to_s.ljust(30),
          photo.username.ljust(30),
          photo.image_url.to_s.ljust(70),
          photo.url.to_s.ljust(70)
        ].join
        row = (urls.index(photo.url.to_s) || ws.num_rows) + 1
        existing_usable_tag = ws[row,HEADERS.index('usable_tag')+1]
        usable_tag = existing_usable_tag
        usable_tag = tag if AUTO_APPROVE && existing_usable_tag.blank?
        [
          provider_name, 
          tag, 
          photo.datetime.iso8601, 
          photo.username, 
          usable_tag, 
          photo.image_url, 
          photo.url,
          photo.image_url_s,
          photo.image_url_m,
          photo.license,
          photo.title,
        ].each_with_index do |value,i|
          ws[row,i+1] = value
        end
      end
    end
    ws.save unless OPTS[:debug]
  end
end

providers = []
providers << TwitterProvider if TWITTER_KEY
providers << FlickrProvider if FLICKR_KEY
providers << InstagramProvider if INSTAGRAM_KEY
if GOOGLE_APPLICATION_CREDENTIALS && GOOGLE_SPREADSHEET_ID
  write_to_google(providers, TAGS)
else
  write_to_csv(providers, TAGS)
end
