module ActiveRecordExtensions
  module EachUpdate
    def each_update!(attributes)
      each do |record|
        record.update!(attributes)
      end
    end

    def each_update(attributes)
      each do |record|
        record.update(attributes)
      end
    end
  end
end

ActiveRecord::Relation.include ActiveRecordExtensions::EachUpdate
