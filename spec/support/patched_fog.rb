require 'fog/openstack/requests/image/create_image'
require 'fog/openstack/requests/image/delete_image'
require 'fog/openstack/requests/image/list_public_images_detailed'

module PatchedFog
  def self.included(spec)
    spec.before do
      stub_const('::Fog::Image::OpenStack::Mock', PatchedFog::ImageMock)
      stub_const('::Fog::Time', ::Time)
    end
  end

  class ImageMock < Fog::Image::OpenStack::Mock
    def delete_image(image_id)
      # Temporarily do what Fog's mock should have done–keep state of images up to date.
      self.data[:images].delete(image_id)
      super(image_id)
    end
  end
end
