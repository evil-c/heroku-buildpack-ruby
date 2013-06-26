require "language_pack"
require "language_pack/rails2"

# Rails 3 Language Pack. This is for all Rails 3.x apps.
class LanguagePack::Rails3 < LanguagePack::Rails2
  # detects if this is a Rails 3.x app
  # @return [Boolean] true if it's a Rails 3.x app
  def self.use?
    if gemfile_lock?
      rails_version = LanguagePack::Ruby.gem_version('railties')
      rails_version >= Gem::Version.new('3.0.0') && rails_version < Gem::Version.new('4.0.0') if rails_version
    end
  end

  def name
    "Ruby/Rails"
  end

  def default_process_types
    # let's special case thin here
    web_process = gem_is_bundled?("thin") ?
                    "bundle exec thin start -R config.ru -e $RAILS_ENV -p $PORT" :
                    "bundle exec rails server -p $PORT"

    super.merge({
      "web" => web_process,
      "console" => "bundle exec rails console"
    })
  end

private
  
  def cache_base
    Pathname.new('/app/tmp/cache/repo')
  end

  def plugins
    super.concat(%w( rails3_serve_static_assets )).uniq
  end

  # runs the tasks for the Rails 3.1 asset pipeline
  def run_assets_precompile_rake_task
    log("assets_precompile") do
      setup_database_url_env

      if rake_task_defined?("assets:precompile")
        topic("Preparing app for Rails asset pipeline")
        if File.exists?("public/assets/manifest.yml")
          puts "Detected manifest.yml, assuming assets were compiled locally"
        elsif precompiled_assets_are_cached?
          puts "Assets already compiled, loading from cache"
          cache_load "public/assets"
        else
          ENV["RAILS_GROUPS"] ||= "assets"
          ENV["RAILS_ENV"]    ||= "production"

          puts "Running: rake assets:precompile"
          require 'benchmark'
          time = Benchmark.realtime { pipe("env PATH=$PATH:bin bundle exec rake assets:precompile 2>&1") }

          if $?.success?
            log "assets_precompile", :status => "success"
            puts "Asset precompilation completed (#{"%.2f" % time}s)"
            cache_assets
          else
            log "assets_precompile", :status => "failure"
            puts "Precompiling assets failed, enabling runtime asset compilation"
            install_plugin("rails31_enable_runtime_asset_compilation")
            puts "Please see this article for troubleshooting help:"
            puts "http://devcenter.heroku.com/articles/rails31_heroku_cedar#troubleshooting"
          end
        end
      end
    end
  end

  # setup the database url as an environment variable
  def setup_database_url_env
    ENV["DATABASE_URL"] ||= begin
      # need to use a dummy DATABASE_URL here, so rails can load the environment
      scheme =
        if gem_is_bundled?("pg")
          "postgres"
        elsif gem_is_bundled?("mysql")
          "mysql"
        elsif gem_is_bundled?("mysql2")
          "mysql2"
        elsif gem_is_bundled?("sqlite3") || gem_is_bundled?("sqlite3-ruby")
          "sqlite3"
        end
      "#{scheme}://user:pass@127.0.0.1/dbname"
    end
  end

  # Stash uncompiled assets away, so we can run a diff against them the next time we deploy
  # Also write our configuration hash to 'public/assets/.version' for comparison on next deploy
  def cache_assets
    puts "Caching assets"
    write_asset_configuration_version
    ["public/assets", * uncompiled_cache_directories].each { |directory| 
      puts "===> caching: #{directory}"
      cache_store(directory) 
    }
  end

  # Have the assets changed since we last pre-compiled them?
  def precompiled_assets_are_cached?
    puts "===> cache_base: #{cache_base}"
    puts "===> File.exist?(#{cache_base}/public/assets/.version): #{File.exist?("#{cache_base}/public/assets/.version")}"
    File.exist?("#{cache_base}/public/assets/.version")  &&
    File.read("#{cache_base}/public/assets/.version") == asset_configuration_hash &&
    uncompiled_cache_directories.all? { |directory| 
      puts "===> diff #{directory} #{cache_base + directory} --recursive" 
      run("diff #{directory} #{cache_base + directory} --recursive").split("\n").length.zero? 
    }
  end

  # The app may change the sprocket configuration from time to time.
  # For example, another file may need to be precompiled,
  # or another folder may be added to the asset path.
  def asset_configuration_hash
    # Find all non-cached, non-vendored references to 'config.assets',
    # strip whitespace, and turn into a hash
    @asset_configuration_hash ||= run("grep -r 'config.assets' . | grep -v './#{cache_base}' | grep -v './tmp' | grep -v './vendor' | sed -e 's/ *//g;' | shasum")[0...-2].strip
  end

  # These are the directories we run a diff against to determine whether to re-compile our assets.
  # If any lines in any files in any of these directories change, we will re-compile.
  # Gemfile.lock is included to try to catch any changes in bundled assets
  def uncompiled_cache_directories
    @uncompiled_cache_directories ||= [
      'Gemfile.lock',
      * Dir['**/*.{js*,coffee,css*,gif,jpg,jpeg,png,sass,scss}'].map { |file| File.dirname(file) }.uniq
    ]
  end

  def write_asset_configuration_version
    begin
      File.open("#{cache_base}/public/assets/.version", "w+") { |file| file.write(asset_configuration_hash) }
      puts "===> .version file <==="
      puts run("cat #{cache_base}/public/assets/.version")
    rescue Exception => e
      puts "===> BORK <==="
      puts e.message
      puts e.backtrace.join("\n")
    end
  end
end
