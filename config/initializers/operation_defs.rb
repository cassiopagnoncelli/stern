def list_operations
  operation_files = Dir[Rails.root.join('..', '..', 'app', 'operations', 'stern', '*.rb')]
  operation_files.each { |file| require file }

  operation_classes = []
  ObjectSpace.each_object(Class) do |obj|
    operation_classes << obj if obj.superclass == Stern::BaseOperation
  end

  operation_classes
end
