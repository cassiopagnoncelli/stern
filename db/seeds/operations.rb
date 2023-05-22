def seed_operations
  operation_files = Dir[Rails.root.join('..', '..', 'app', 'operations', 'stern', '*.rb')]
  operation_files.each { |file| require file }

  operation_classes = []
  ObjectSpace.each_object(Class) do |obj|
    operation_classes << obj if obj.superclass == Stern::BaseOperation
  end

  operation_classes.each do |op|
    name = op.name.gsub('Stern::', '')
    unless Stern::Operation.find_by(name:)
      record = Stern::Operation.create!(name:)
      record.update!(active: true, undo_capability: op.new.respond_to?(:undo))
    end
  end
end
