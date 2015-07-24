module VmShepherd
  module DataObject
    def ==(other_obj)
      return false unless self.class === other_obj

      instance_variables.all? do |ivar_name|
        self.instance_variable_get(ivar_name) == other_obj.instance_variable_get(ivar_name)
      end
    end
  end
end
