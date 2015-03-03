# open is used by RbvMomi when trying to upload OVA file.
# It does not support local file upload without following patch.
module Kernel
  private
  alias open_without_file open
  class << self
    alias open_without_file open
  end

  def open(name, *rest, &blk)
    name = name[7..-1] if name.start_with?('file://')
    open_without_file(name, *rest, &blk)
  end
end
