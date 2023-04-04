class ApplicationRecord < ActiveRecord::Base
  primary_abstract_class

  establish_connection "stern_#{Rails.env}".to_sym
end
