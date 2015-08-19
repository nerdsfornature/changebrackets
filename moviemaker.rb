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
  # make a movie for tag morganfire01 using a config file
  bundle exec ruby moviemaker.rb -c fireslurp.yaml morganfire01

  # Do the same with a larger width and writing to a directory
  bundle exec ruby moviemaker.rb -c fireslurp.yaml morganfire01 -f t1 -w 1024

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
  opt :limit, "Limit the stitch to the first n files. Just for testing.", :type => :integer
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
  cmd = cmd.gsub(/\s+/m, ' ')
  puts "Running #{cmd}" if OPTS[:debug]
  system cmd
end



# Lifted from activesupport/lib/active_support/core_ext/array/grouping.rb, line 20
class Array
  def in_groups_of(number, fill_with = nil)
    if fill_with == false
      collection = self
    else
      # size % number gives how many extra we have;
      # subtracting from number gives how many to add;
      # modulo number ensures we don't add group of just fill.
      padding = (number - size % number) % number
      collection = dup.concat(Array.new(padding, fill_with))
    end

    if block_given?
      collection.each_slice(number) { |slice| yield(slice) }
    else
      collection.each_slice(number).to_a
    end
  end
end

def download_images
  puts "DOWNLOADING IMAGES"  if OPTS[:debug]
  session = GoogleDrive.login(GOOGLE_EMAIL, GOOGLE_PASSWORD)
  ws = session.spreadsheet_by_key(GOOGLE_SPREADSHEET_ID).worksheets[0]
  rows = ws.rows.select {|r| @tag == r[HEADERS.index('usable_tag')]}
  rows.each_with_index do |row,i|
    next if OPTS.limit && OPTS.limit < i+1
    provider, row_tag, datetime, username, usable_tag, image_url, url, image_url_s, image_url_m, license, title = row
    next unless @tag == usable_tag
    if image_url.empty?
      puts "\timage_url blank, skipping..."
      next
    end
    base = File.basename(image_url)
    ext = File.extname(image_url).split(':')[0]
    fname = "#{@tag}+#{datetime}+#{provider}+#{username}+#{base.split('.')[0]}#{ext}".gsub(/[^A-z0-9\+\-\_\.]+/, '_')
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
  prefix = "#{options[:prefix] || "#{@tag}+"}*"
  system_call "rm #{@work_path}/resized+*"
  Dir.glob(File.join(@work_path, prefix)).each do |path|
    basename = File.basename(path)
    system_call "convert #{path} -resize #{OPTS[:width]} #{@work_path}/resized+#{basename}"
  end
end

def align_images
  puts "ALIGNING" if OPTS[:debug]
  window = 70
  paths = Dir.glob(File.join(@work_path, "resized+*")).map{|p| p.split('/').last}
  (paths.size / 10.0).ceil.times do |i|
    puts "WINDOW #{i}"
    batch_paths = paths[i*window, window] || []
    puts "Batch paths:"
    batch_paths.each do |p|
      puts "\t#{p}"
    end
    all_paths = batch_paths
    system_call "cd #{@work_path} && #{OPTS[:timelapsing]} #{all_paths.join(' ')}" if all_paths.compact.size > 0
  end
end

def create_movie_images
  puts "CREATING MOVIE FRAMES" if OPTS[:debug]
  prefix = if OPTS[:skip_alignment]
    "resized+"
  else
    "resized+fixed_"
  end
  dates, paths = [], []
  paths_by_date = {}
  Dir.glob(File.join(@work_path, "#{prefix}*")).each do |path|
    paths << path
    date = path[/\d{4}-\d{2}-\d{2}/, 0]
    dates << date
    paths_by_date[date] ||= []
    paths_by_date[date] << path
  end
  dates = dates.compact.sort
  start = DateTime.parse(dates.min).to_date
  stop = DateTime.parse(dates.max).to_date + 10 # pad with 10 days
  src_path = nil
  (start..stop).each do |date|
    src_path = if paths_by_date[date.to_s] && (path = paths_by_date[date.to_s].first)
      path
    else
      src_path
    end
    next unless src_path
    dest_path = File.join(File.dirname(src_path), "movie+#{date}+#{File.basename(src_path)}")
    pieces = File.basename(src_path).split('+')
    provider, photographer = pieces[-3], pieces[-2].to_s.gsub(/_/, ' ')
    inset = OPTS[:width] * 0.02
    system_call <<-BASH
      convert #{src_path} \
        -gravity northwest -background black -extent #{OPTS[:width]}x#{OPTS[:width]} \
        -font Helvetica-Bold -pointsize #{inset} -fill white -gravity northwest -annotate +#{inset}+#{inset} '#{date}' \
        -font Helvetica      -pointsize #{inset} -fill white -gravity north     -annotate +#{inset}+#{inset} 'Photo (c) #{photographer}' \
        -font Helvetica      -pointsize #{inset} -fill white -gravity northeast -annotate +#{inset}+#{inset} 'Via #{provider}' \
        #{dest_path}
    BASH
  end
end

def create_movie
  puts "CREATING MOVIE" if OPTS[:debug]
  system_call <<-BASH
    mencoder mf://#{File.join(@work_path, "movie+*")} \
      -mf w=#{OPTS[:width]}:h=#{OPTS[:width]}:fps=15 \
      -ovc x264 \
      -oac copy \
      -o #{File.join(@work_path, "#{@tag}.avi")}
  BASH
end

download_images unless OPTS[:skip_download]
resize_images
align_images unless OPTS[:skip_alignment]
resize_images(:prefix => "fixed_")
create_movie_images
create_movie
