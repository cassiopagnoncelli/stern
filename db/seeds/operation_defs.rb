def seed_operation_defs
  operation_files = Dir[Rails.root.join('..', '..', 'app', 'operations', 'stern', '*.rb')]
  operation_files.each { |file| require file }

  operation_classes = []
  ObjectSpace.each_object(Class) do |obj|
    operation_classes << obj if obj.superclass == Stern::BaseOperation
  end

  operation_classes.each do |op|
    name = op.name.gsub('Stern::', '')
    unless Stern::OperationDef.find_by(name:)
      Stern::OperationDef.create!(
        name:,
        active: true,
        undo_capability: op.new.respond_to?(:perform_undo),
      )
      Rails.logger.info "Registered operation #{name}"
    end
  end
end
