require 'rubygems'
require 'google_drive'
require 'open-uri'
require 'trollop'
require 'yaml'

OPTS = Trollop::options do
    banner <<-EOS
Download image files listed in fireslurp's Google Spreadsheet and make a
timelapse movie.

Usage:

  bundle exec ruby moviemaker.rb -c fireslurp.yaml morganfire01

where [options] are:
EOS
  opt :debug, "Print debug statements", :type => :boolean, :short => "-d"
  opt :config, "Path to YAML configuration file", :type => :string, :short => "-c"
  opt :folder, "Folder to write images and movie", :type => :string, :short => "-f"
  opt :width, "Width of the movie", :type => :integer, :short => "-w", :default => 500
  opt :skip_download, "Skip the downloads and assume files are already in the work path", :type => :boolean, :default => false
  opt :skip_alignment, "Skip the alignment and assume files are already in the work path", :type => :boolean, :default => false
  opt :google_email, "Google email address, used to add data to a Google spreadsheet", :type => :string
  opt :google_password, "Google account password", :type => :string
  opt :google_spreadsheet_id, "
    Write data to a Google Spreadsheet instead of CSV. The value should be the
    Google Spreadhseet ID. If it's blank and the flag is used, the script will
    look for an internal variable.
  ".strip, :type => :string, :short => '-g'
  opt :timelapsing, "timelapsing_detailed command (could be full path to binary)", :type => :string, :default => "timelapsing_detailed"
end

config = if OPTS[:config] && File.exists?(OPTS[:config])
  YAML.load_file(OPTS[:config])
else
  {}
end

## CONFIG ###############################################
GOOGLE_EMAIL          = OPTS[:google_email]           || config['google_email']
GOOGLE_PASSWORD       = OPTS[:google_password]        || config['google_password']
GOOGLE_SPREADSHEET_ID = OPTS[:google_spreadsheet_id]  || config['google_spreadsheet_id']
###############################################################

HEADERS = %w(provider tag datetime username usable_tag image_url url image_url_s image_url_m license title)

@tag = ARGV[0].to_s.gsub(/[#\s]/, '')
@work_path = if OPTS[:folder]
  File.expand_path(OPTS[:folder])
else
  File.join(Dir::tmpdir, "#{@tag}-#{Time.now.to_i}")
end
FileUtils.mkdir_p @work_path, :mode => 0755

def system_call(cmd)
  puts "Running #{cmd}" if OPTS[:debug]
  system cmd
end

def download_images
  puts "DOWNLOADING IMAGES"  if OPTS[:debug]
  session = GoogleDrive.login(GOOGLE_EMAIL, GOOGLE_PASSWORD)
  ws = session.spreadsheet_by_key(GOOGLE_SPREADSHEET_ID).worksheets[0]
  rows = ws.rows.select {|r| @tag == r[HEADERS.index('usable_tag')]}
  rows.each_with_index do |row,i|
    provider, row_tag, datetime, username, usable_tag, image_url, url, image_url_s, image_url_m, license, title = row
    next unless @tag == usable_tag
    base = File.basename(image_url)
    ext = File.extname(image_url).split(':')[0]
    fname = "#{@tag}-#{datetime}-#{provider}-#{username}-#{base.split('.')[0]}#{ext}".gsub(/[^A-z0-9\-\_\.]+/, '_')
    path = File.join(@work_path, fname)
    puts "#{i+1} of #{rows.size}, writing\n\t#{image_url} to \n\t#{path}"
    begin
      f = open(image_url)
      open(path, 'wb') do |file|
        file << f.read
      end
      f.close
    rescue OpenURI::HTTPError => e
      if e.message =~ /404 Not Found/
        puts "\tImage gone"
      end
    end
  end
end

def resize_images(options = {})
  puts "RESIZING RAW IMAGES"  if OPTS[:debug]
  prefix = "#{options[:prefix] || "#{@tag}-"}*"
  Dir.glob(File.join(@work_path, prefix)).each do |path|
    basename = File.basename(path)
    system_call "convert #{path} -resize #{OPTS[:width]} #{@work_path}/resized-#{basename}"
  end
end

def align_images
  puts "ALIGNING" if OPTS[:debug]
  system_call "cd #{@work_path} && #{OPTS[:timelapsing]} resized-*"
end

def create_movie
  puts "CREATING MOVIE" if OPTS[:debug]
  system_call "convert -delay 30 #{@work_path}/resized-fixed_* #{@work_path}/#{@tag}.gif"
end

download_images unless OPTS[:skip_download]
resize_images
align_images unless OPTS[:skip_alignment]
resize_images(:prefix => "fixed_")
create_movie
