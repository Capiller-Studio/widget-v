# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AvatarHelper, type: :helper do
  describe '#avatar_fallback_color_class' do
    it 'returns a deterministic color class between 1 and 8' do
      expect(helper.avatar_fallback_color_class('Alice')).to match(/\Aavatar-fallback-[1-8]\z/)
      expect(helper.avatar_fallback_color_class('Bob')).to match(/\Aavatar-fallback-[1-8]\z/)
    end

    it 'returns the exact same class for the same name regardless of whitespace and case' do
      expect(helper.avatar_fallback_color_class('John Doe')).to eq(helper.avatar_fallback_color_class('  john doe  '))
    end

    it 'returns avatar-fallback-1 for blank names' do
      expect(helper.avatar_fallback_color_class('')).to eq('avatar-fallback-1')
      expect(helper.avatar_fallback_color_class(nil)).to eq('avatar-fallback-1')
    end
  end
end
