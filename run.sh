#!/bin/sh

# http://stackoverflow.com/questions/3878624/how-do-i-programmatically-determine-if-there-are-uncommited-changes
require_clean_work_tree () {
  # Update the index
  git update-index -q --ignore-submodules --refresh
  err=0

  # Disallow unstaged changes in the working tree
  if ! git diff-files --quiet --ignore-submodules --; then
      echo >&2 "cannot deploy to heroku: you have unstaged changes."
      git diff-files --name-status -r --ignore-submodules -- >&2
      err=1
  fi

  # Disallow uncommitted changes in the index
  if ! git diff-index --cached --quiet HEAD --ignore-submodules --; then
      echo >&2 "cannot deploy to heroku: your index contains uncommitted changes."
      git diff-index --cached --name-status -r --ignore-submodules HEAD -- >&2
      err=1
  fi

  if [ $err = 1 ]; then
      echo >&2 "please commit or stash them."
      exit 1
  fi
}

echo "===================================================="
echo "                 DEPLOYING WITH STYLE :-)"
echo "===================================================="
cd discourse

# http://stackoverflow.com/questions/1593051/how-to-programmatically-determine-the-current-checked-out-git-branch
CALLER_BRANCH="$(git rev-parse --symbolic-full-name --abbrev-ref HEAD)"

echo "============ checking working tree status, must be clear ============"
require_clean_work_tree

echo "============ creating deploy branch ============"
git checkout -b deploy_to_heroku

echo "============ configuring redis ============"
redis_config=config/redis.yml
cp -f config/redis.yml.sample $redis_config
# using Redis Cloud, need to replace the env variable and cache db index
sed -i 's/REDIS_PROVIDER_URL/REDISCLOUD_URL/g' $redis_config
sed -i 's/cache_db: 2/cache_db: 0/g' $redis_config
sed -i '/^.*redis.yml.*$/ s/^/#/' .gitignore # unignore redis configuration

echo "============ configuring mail ============"
rails_config=config/environments/production.rb
cp -f config/environments/production.rb.sample $rails_config
sed -i '/^.*action_mailer.delivery_method.*$/d' $rails_config
sed -i '/^.*action_mailer.sendmail_settings.*$/d' $rails_config
sed -i "/^.*eg: sendgrid.*/ a\
  config.action_mailer.delivery_method = :smtp\n \
  config.action_mailer.smtp_settings = {\n \
    :port =>           ENV['SMTP_PORT'],\n \
    :address =>        ENV['SMTP_SERVER'],\n \
    :user_name =>      ENV['MANDRILL_USERNAME'],\n \
    :password =>       ENV['MANDRILL_APIKEY'],\n \
    :domain =>         'heroku.com',\n \
    :authentication => :plain\n \
  }" $rails_config
sed -i '/^.*production.rb.*$/ s/^/#/' .gitignore # unignore production configuration

echo "============ removing clockwork ============"
sed -i '/^clockwork.*$/d' Procfile

#echo "============ using Rails 4 ============"
#export RAILS4=true

echo "============ configuring sidekiq & autoscaler ============"
sed -i '/^source/ a\\ngem "autoscaler", require: false' Gemfile
sidekiq_config=config/initializers/sidekiq.rb
sed -i '1!d' $sidekiq_config
sed -i "$ a\
  if Rails.env.production?\n \
    require 'autoscaler/sidekiq'\n \
    require 'autoscaler/heroku_scaler'\n \
    \n \
    Sidekiq.configure_server do |config|\n \
      config.redis = sidekiq_redis\n \
      config.server_middleware do |chain|\n \
        chain.add(Autoscaler::Sidekiq::Server, Autoscaler::HerokuScaler.new('sidekiq'), 60)\n \
      end\n \
      Sidetiq::Clock.start\!\n \
    end\n \
    \n \
    Sidekiq.configure_client do |config|\n \
      config.redis = sidekiq_redis\n \
      config.client_middleware do |chain|\n \
        chain.add Autoscaler::Sidekiq::Client, 'default' => Autoscaler::HerokuScaler.new('sidekiq')\n \
      end\n \
    end\n \
  else\n \
    Sidekiq.configure_server do |config|\n \
      config.redis = sidekiq_redis\n \
      Sidetiq::Clock.start\!\n \
    end\n \
    \n \
    Sidekiq.configure_client { |config| config.redis = sidekiq_redis }\n \
    Sidekiq.logger.level = Logger::WARN\n \
  end\n \
  \n \
  Sidetiq.configure do |config|\n \
    # we only check for new jobs once every 5 seconds\n \
    # to cut down on cpu cost\n \
    config.resolution = 5\n \
  end \
  " $sidekiq_config

echo "============ configuring database settings ============"
db_config=config/database.yml
db_username=discourse
db_password=discourse
db_name=discourse_deployment
cp -f config/database.yml.development-sample $db_config # use development sample
# add credentials
sed -i '/^development:/ a\  username: '$db_username'\n  password: '$db_password $db_config
sed -i '/^test:/ a\  username: '$db_username'\n  password: '$db_password $db_config
sed -i '/^production:/ a\  username: '$db_username'\n  password: '$db_password $db_config
# use specific database
sed -i '/^.*database:.*$/d' $db_config
sed -i '/^development:/ a\  database: '$db_name'_development' $db_config
sed -i '/^test:/ a\  database: '$db_name'_test' $db_config
sed -i '/^production:/ a\  database: '$db_name'_development' $db_config

#echo "============ setting ruby version ============"
#sed -i '/^source/ a\\nruby "2.0.0"' Gemfile

echo "============ bundling ============"
bundle install

echo "============ building database, to be able to precompile assets ============"
bundle exec rake db:drop
bundle exec rake db:create
bundle exec rake db:migrate
bundle exec rake db:seed_fu
# TODO: should I also replace production.localhost ???

echo "============ precompiling assets ============"
export SECRET_TOKEN=***************REPLACE_ME***************
bundle exec rake assets:precompile
sed -i '/^.*public.assets.*$/ s/^/#/' .gitignore # unignore assets
unset SECRET_TOKEN

echo "============ dropping deployment database ============"
bundle exec rake db:drop
rm -f $db_config

echo "============ commiting changes ============"
git add -A .
git commit -m "prepared for Heroku deployment"

#echo "============ package locally fixed gems ============"
#bundle package --all
#git add -A .
#git commit -m "added packaged gems"

#echo "============ unsetting Rails 4 ============"
#unset RAILS4

echo "============ pushing to heroku ============"
# http://stackoverflow.com/questions/2971550/how-to-push-different-local-git-branches-to-heroku-master
git push -f heroku HEAD:master

echo "============ migrating heroku database ============"
heroku run rake db:migrate

echo "============ returning to trigger branch ============"
git checkout $CALLER_BRANCH

echo "============ removing deploy branch ============"
git branch -D deploy_to_heroku

echo "===================================================="
echo "                 THAT'S ALL FOLKS"
echo "===================================================="
cd ..
