require 'bundler/setup'
Bundler.require

ActiveRecord::Base.establish_connection(ENV['DATABASE_URL']||"sqlite3:db/development.db")

class User < ActiveRecord::Base
  has_many :assignment
end

class Assignment < ActiveRecord::Base
  belongs_to :user
end