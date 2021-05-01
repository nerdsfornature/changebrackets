require 'rubygems'
require 'twitter'
require 'pp'
require 'active_support/inflector'
require 'ostruct'
require 'flickraw'
require 'csv'
require 'googleauth'
require 'google/apis/sheets_v4'
require 'optimist'
require 'yaml'

OPTS = Optimist::options do
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
  # Save info about Twitter photos for two tags in a local CSV file
  bundle exec ruby fireslurp.rb \
    --twitter-key=xxx \
    --twitter-secret=yyy \
    morganfire01 morganfire02

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
GOOGLE_APPLICATION_CREDENTIALS  = OPTS[:google_application_credentials]   || config['google_application_credentials']
GOOGLE_SPREADSHEET_ID           = OPTS[:google_spreadsheet_id]            || config['google_spreadsheet_id']
AUTO_APPROVE                    = OPTS[:auto_approve]                     || config['auto_approve']
###############################################################

HEADERS = %w(provider tag datetime username usable_tag image_url url image_url_s image_url_m license title)

Trollop::die "you must specify at least one tag" if ARGV.empty?
Trollop::die "you must specify at least one API key" if [TWITTER_KEY, FLICKR_KEY].compact.reject(&:blank?).blank?
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

def sheets_col( col )
  "ABCDEFGHIJKLMNOPQRSTUVWXYZ"[HEADERS.index(col)]
end

def write_to_google(providers, tags)
  sheets = Google::Apis::SheetsV4::SheetsService.new
  sheets.authorization = google_access_token
  ws = sheets.get_spreadsheet(GOOGLE_SPREADSHEET_ID).sheets[0]
  ws_title = ws.properties.title
  header = sheets.get_spreadsheet_values(GOOGLE_SPREADSHEET_ID, "#{ws_title}!1:1").values
  if !header || header[0].blank? || header.size == 0
    header_range = "#{ws_title}!1:1"
    unless OPTS[:debug]
      sheets.update_spreadsheet_value(
        GOOGLE_SPREADSHEET_ID,
        header_range,
        Google::Apis::SheetsV4::ValueRange.new(range: header_range, values: [HEADERS]),
        value_input_option: 'USER_ENTERED'
      )
    end
  end
  url_col_range = "#{ws_title}!#{sheets_col('url')}:#{sheets_col('url')}"
  usable_tag_col_range = "#{ws_title}!#{sheets_col('usable_tag')}:#{sheets_col('usable_tag')}"
  providers.each do |provider|
    provider_name = provider.name.underscore.split('_').first.capitalize
    puts
    tags.each do |tag|
      provider.search(tag) do |photo|
        next unless photo
        urls = sheets.get_spreadsheet_values(GOOGLE_SPREADSHEET_ID, url_col_range).values.flatten
        usable_tags = sheets.get_spreadsheet_values(GOOGLE_SPREADSHEET_ID, usable_tag_col_range).values.flatten
        puts [
          provider_name.ljust(10),
          tag.ljust(15),
          photo.datetime.to_s.ljust(30),
          photo.username.ljust(30),
          photo.image_url.to_s.ljust(70),
          photo.url.to_s.ljust(70)
        ].join
        usable_tag = tag if AUTO_APPROVE
        if existing_row_i = urls.index(photo.url.to_s)
          existing_usable_tag = usable_tags[existing_row_i]
          usable_tag = existing_usable_tag unless existing_usable_tag.blank?
        end
        values = [
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
        ]
        unless OPTS[:debug]
          if existing_row_i
            row_range = "#{ws_title}!#{existing_row_i + 1}:#{existing_row_i + 1}"
            sheets.update_spreadsheet_value(
              GOOGLE_SPREADSHEET_ID,
              row_range,
              Google::Apis::SheetsV4::ValueRange.new(range: row_range, values: [values]),
              value_input_option: 'USER_ENTERED'
            )
          else
            sheets.append_spreadsheet_value(
              GOOGLE_SPREADSHEET_ID,
              "#{ws_title}!A1:Z1",
              Google::Apis::SheetsV4::ValueRange.new(values: [values]),
              value_input_option: 'USER_ENTERED'
            )
          end
        end
      end
    end
    # ws.save unless OPTS[:debug]
  end

  # 2021-04-28 ok, this all works but you quickly run into google's quoata
  # limitations b/c you're requesting data from the sheet for *every* single
  # photo. It's also no robust against token expiry, which it should be if this
  # is going to run for a while. Sooo, what I need to do is to make yet another
  # service class that reads the sheet, exposes read and write operations on a
  # *local* copy of the data, commits changes all in one request, catches
  # exceptions like Google::Apis::RateLimitError and waits, and catches
  # Google::Apis::AuthorizationError and fetches a new token
  # Useful urls:
  #  https://developers.google.com/sheets/api/samples/writing
  #  https://developers.google.com/sheets/api/guides/values#ruby_2
  #  https://github.com/googleapis/google-api-ruby-client/blob/master/samples/cli/lib/samples/sheets.rb
end

providers = []
providers << TwitterProvider if TWITTER_KEY
providers << FlickrProvider if FLICKR_KEY
if GOOGLE_APPLICATION_CREDENTIALS && GOOGLE_SPREADSHEET_ID
  write_to_google(providers, TAGS)
else
  write_to_csv(providers, TAGS)
end

