# changebrackets

This is a public repo for our project that uses 
[angle brackets to monitor environmental change](http://nerdsfornature.org/monitor-change), 
including the scripts we use harvest image metadata, display a slideshow on a
web page, download images, and compile movies. We've also included our sign
designs.

## SCRIPTS
These are a couple Ruby scripts we use to help automate the process of getting
information about tag usage and making timelapse movies from the images. You
don't need to know Ruby to use them, but you should be comfortable with
running scripts from the command line. These instructions presume you're
runnign some flavor of *nix, but all the underlying libraries are available
for Windows so these scripts should work there too.

### REQUIREMENTS
* [Ruby](https://www.ruby-lang.org)
* [Rubygems](https://rubygems.org)
* [Bundler](http://bundler.io)
* [TimeLapser](https://github.com/pglotov/TimeLapser) (this is an OpenCV-based C++ binary for aligning images, see the repo for installation instructions)
* [ImageMagick](http://www.imagemagick.org/)

### INSTALL
```bash
git clone https://github.com/nerdsfornature/changebrackets.git
cd changebrackets
bundle
```

### fireslurp.rb
This Ruby script harvests image metadata from social media photos using your
tags and stores them in local CSV files or a Google Spreadsheet. Run
`ruby fireslurp.rb --help` to see all the options, but basic usage looks like this:

```bash
# Save info about Instagram photos for two tags in a local CSV file
bundle exec ruby fireslurp.rb --instagram-key=xxx morganfire01 morganfire02

# Save info about Twitter photos for two tags to a Google Spreadsheet
bundle exec ruby fireslurp.rb \
  --twitter-key=xxx \
  --twitter-secret=yyy \
  --google-email=your.email@gmail.com \
  --google-password=worstpasswordevar \
  --google-spreadsheet-id=1234abcd \
  morganfire01 morganfire02

# Save info about photos for two tags using config from a YAML file
bundle exec ruby fireslurp.rb -c fireslurp.yaml morganfire01 morganfire02
```

The last option using a config file is probably the easiest way to go.
`fireslurp.yaml` provides an example for the config file. The Google
Spreadsheet ID is just the unique part of your Google Spreadsheet URL, so if
the URL when you're editing it looks like 
`https://docs.google.com/spreadsheets/d/1HF1fEF4j69Ny6ng9TZYNLYnnRb4J6mPCqmckyOrsomI/edit`, 
then the ID is `1HF1fEF4j69Ny6ng9TZYNLYnnRb4J6mPCqmckyOrsomI`. Note that to
use a Google Spreadsheet, the user you provide the email and password for must
having editing privileges.

Note that this script only retrieves info about *recent* photos, so it should
be run at least daily, more often if your tags get a lot of use.
We recommend [cron](http://www.unixgeeks.org/security/newbie/unix/cron-1.html) or 
[launchd](https://developer.apple.com/library/mac/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html).

### moviemaker.rb
Downloads the image files referenced in a Google Spreadsheet made by
`fireslurp.rb`, aligns them using
[TimeLapser](https://github.com/pglotov/TimeLapser), and stitches them into an
animated GIF using ImageMagick. This is really just a little bit of logic on
top of some basic shell commands, which should be pretty obvious in the
script. Note that you can force it to download the files to a particular
folder using the `-f` flag, and skip the relatively slow processes of
downloading and alignment.

```bash
# Basic usage
bundle exec ruby moviemaker.rb -c fireslurp.yaml morganfire01

# Download all the image files to a folder named myfolder
bundle exec ruby moviemaker.rb -c fireslurp.yaml -f myfolder morganfire01

# Skip download, just do the alignment based on files in myfolder, and make the movie
bundle exec ruby moviemaker.rb -c fireslurp.yaml -f myfolder --skip-download morganfire01
```

## CHANGEOMATIC
This is a little jQuery-based tool that sort of does what fireslurp does in
the browser by pulling in photo data and creating a slideshow. It will only
retrieve photos from Flickr and Instagram due to the
[limitations of Twitter's API](http://stackoverflow.com/questions/17004070/making-jquery-ajax-call-to-twitter-api-1-1-search)
in a strictly client-side context like this.


### Using Google Spreadsheet
It can also read data from a Google Spreadsheet made by fireslurp, which is
one way of getting around the Twitter thing, though doing so requires that you
[publish your Google Spreadsheet](https://support.google.com/docs/answer/37579).

### REQUIREMENTS
* [jQuery](http://jquery.com/)
* [cycle2](http://jquery.malsup.com/cycle2/)
* [cycle2.center](http://jquery.malsup.com/cycle2/demo/center.php)
* [jQuery-dateFormat](https://github.com/phstc/jquery-dateFormat)
* [tabletop](https://github.com/jsoma/tabletop)

### USAGE
See `changeomatic.example.html`
