require "dry/core/class_builder"
require "dry/types"
require "dry/struct"

require "dry/system/settings/file_loader"
require "dry/system/constants"

module Dry
  module System
    module Settings
      class DSL < BasicObject
        attr_reader :identifier

        attr_reader :schema

        def initialize(identifier, &block)
          @identifier = identifier
          @schema = {}
          instance_eval(&block)
        end

        def call
          Core::ClassBuilder.new(name: 'Configuration', parent: Settings::Configuration).call do |klass|
            schema.each do |key, type|
              klass.setting(key, type)
            end
          end
        end

        def key(name, type)
          schema[name] = type
        end
      end

      class Configuration < Dry::Struct
        def self.setting(*args)
          attribute(*args)
        end

        def self.load(root, env)
          env_data = load_files(root, env)
          attributes = {}
          errors = {}

          schema.each do |key, type|
            value = ENV.fetch(key.to_s.upcase) { env_data[key.to_s.upcase] }
            type_check = type.try(value || Undefined)

            attributes[key] = value if value
            errors[key] = type_check if type_check.failure?
          end

          raise InvalidSettingsError.new(errors) unless errors.empty?

          new(attributes)
        end

        def self.load_files(root, env)
          FileLoader.new.(root, env)
        end
        private_class_method :load_files
      end
    end
  end
end
