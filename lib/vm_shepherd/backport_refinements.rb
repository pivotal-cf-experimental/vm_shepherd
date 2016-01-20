# rubocop:disable all

module VmShepherd
  module BackportRefinements
    def self.should_refine?
      Gem::Version.new(RUBY_VERSION) < Gem::Version.new('2.3.0')
    end

    def self.ported_dig(obj, indices)
      head = indices.first
      new_obj = obj[head]
      if indices.count == 1
        new_obj
      elsif new_obj == nil
        return nil
      else
        tail = indices[1..-1]
        ported_dig(new_obj, tail)
      end
    end

    def self.ported_dig_for_recursive_open_struct(obj, indices)
      head = indices.first

      if head.is_a?(Integer)
        new_obj = obj[head]
      elsif
        new_obj = obj[head] || obj[head.to_sym]
      end

      if indices.count == 1
        new_obj
      elsif new_obj == nil
        return nil
      else
        tail = indices[1..-1]
        ported_dig(new_obj, tail)
      end
    end

    refine Array do
      next unless BackportRefinements.should_refine?

      def dig(*indices)
        BackportRefinements.ported_dig(self, indices)
      end
    end

    refine Hash do
      next unless BackportRefinements.should_refine?

      def dig(*indices)
        BackportRefinements.ported_dig(self, indices)
      end
    end

    begin
      # This little piece of awful-ness is needed because we back-ported
      # this gem to 1.6 version of OpsManager, which still uses RecursiveOpenStruct
      # because of ops_manager_ui_drivers

      # Therefore, we need this to function in contexts where recursive open struct is
      # a dependency, without leaking into other contexts.

      # Delete this once we stop supporting 1.6

      require 'recursive_open_struct'

      refine RecursiveOpenStruct do
        def dig(*indices)
          BackportRefinements.ported_dig_for_recursive_open_struct(to_h, indices)
        end
      end

    rescue LoadError
    end

  end
end
# rubocop:enable all
