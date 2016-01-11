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
  end
end
