require 'inflecto'
require 'dry-container'
require 'dry-auto_inject'

require 'dry/component/loader'
require 'dry/component/config'

module Dry
  module Component
    class Container
      extend Dry::Container::Mixin

      setting :env
      setting :root, Pathname.pwd.freeze
      setting :auto_register
      setting :app

      class << self
        def configure(env = config.env, &_block)
          unless configured?
            super() do |config|
              Config.load(root, env).tap do |app_config|
                config.app = app_config if app_config
              end
            end

            load_paths!('core')
            @_configured = true
          end

          yield(self) if block_given?

          self
        end

        def finalize(name, &block)
          finalizers[name] = block
        end

        def configured?
          @_configured
        end

        def finalize!(&_block)
          yield(self) if block_given?

          Dir[root.join('core/boot/**/*.rb')].each do |path|
            boot!(File.basename(path, '.rb').to_sym)
          end

          auto_register.each(&method(:auto_register!)) if auto_register?

          freeze
        end

        def import_module
          auto_inject = Dry::AutoInject(self)

          -> *keys {
            keys.each { |key| load_component(key) unless key?(key) }
            auto_inject[*keys]
          }
        end

        def auto_register!(dir, &_block)
          dir_root = root.join(dir.to_s.split('/')[0])

          Dir["#{root}/#{dir}/**/*.rb"].each do |path|
            component_path = path.to_s.gsub("#{dir_root}/", '').gsub('.rb', '')
            Component.Loader(component_path).tap do |component|
              next if key?(component.identifier)

              Kernel.require component.path

              if block_given?
                register(component.identifier, yield(component.constant))
              else
                register(component.identifier) { component.instance }
              end
            end
          end

          self
        end

        def boot!(name)
          check_component_identifier!(name)
          return self unless booted?(name)
          boot(name)
          self
        end

        def boot(name)
          require "core/boot/#{name}.rb"

          finalizers[name].tap do |finalizer|
            finalizer.() if finalizer
          end

          booted[name] = true
        end

        def booted?(name)
          !booted.key?(name)
        end

        def require(*paths)
          paths.flat_map { |path|
            path.include?('*') ? Dir[root.join(path)] : root.join(path)
          }.each { |path|
            Kernel.require path.to_s
          }
        end

        def load_component(key)
          require_component(key) { |klass| register(key) { klass.new } }
        end

        def require_component(key, &block)
          component = Component.Loader(key)
          path = load_paths.detect { |p| p.join(component.file).exist? }

          if path
            Kernel.require component.path
            yield(component.constant) if block
          else
            fail ArgumentError, "could not resolve require file for #{key}"
          end
        end

        def root
          config.root
        end

        def load_paths!(*dirs)
          dirs.map(&:to_s).each do |dir|
            path = root.join(dir)
            load_paths << path
            $LOAD_PATH.unshift(path.to_s)
          end
          self
        end

        def load_paths
          @_load_paths ||= []
        end

        def booted
          @_booted ||= {}
        end

        def finalizers
          @_finalizers ||= {}
        end

        private

        def auto_register
          Array(config.auto_register)
        end

        def auto_register?
          !auto_register.empty?
        end

        def check_component_identifier!(name)
          fail(
            ArgumentError,
            'component identifier must be a symbol'
          ) unless name.is_a?(Symbol)
          fail(
            ArgumentError,
            "component identifier +#{name}+ is invalid or boot file is missing"
          ) unless root.join("core/boot/#{name}.rb").exist?
        end
      end
    end
  end
end
