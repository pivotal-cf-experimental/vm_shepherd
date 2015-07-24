require 'vm_shepherd/data_object'

module VmShepherd
  class TestDataObject
    include DataObject

    attr_accessor :name
  end

  RSpec.describe(DataObject) do
    describe '#==' do
      it 'returns false for objects of a different class' do
        class DifferentDataObject
          include DataObject
        end

        expect(TestDataObject.new == DifferentDataObject.new).to be_falsey
      end

      it 'returns true for objects of a descendent class' do
        class DescendentDataObject < TestDataObject
          include DataObject
        end

        expect(TestDataObject.new == DescendentDataObject.new).to be_truthy
      end

      it 'returns false when any attribute is unequal' do
        a = TestDataObject.new
        b = TestDataObject.new

        a.name = 'a'
        b.name = 'b'

        expect(a == b).to be_falsey
      end

      it 'returns true when all attributes are equal' do
        eleventy_one = TestDataObject.new
        hundred_and_eleven = TestDataObject.new

        eleventy_one.name = '111'
        hundred_and_eleven.name = '111'

        expect(eleventy_one == hundred_and_eleven).to be_truthy
      end
    end
  end
end
