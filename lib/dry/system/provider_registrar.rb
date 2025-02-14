# frozen_string_literal: true

require "dry/core/deprecations"
require "dry/system"
require "pathname"
require_relative "errors"
require_relative "constants"
require_relative "provider"

module Dry
  module System
    # Default provider registrar implementation
    #
    # This is currently configured by default for every Dry::System::Container. The
    # provider registrar is responsible for loading provider files and exposing an API for
    # running the provider lifecycle steps.
    #
    # @api private
    class ProviderRegistrar
      extend Dry::Core::Deprecations["Dry::System::Container"]

      # @api private
      attr_reader :providers

      # @api private
      attr_reader :container

      # @api private
      def initialize(container)
        @providers = {}
        @container = container
      end

      # @api private
      def freeze
        providers.freeze
        super
      end

      # rubocop:disable Metrics/PerceivedComplexity

      # @see Container.register_provider
      # @api private
      def register_provider(name, namespace: nil, from: nil, source: nil, if: true, &block)
        raise ProviderAlreadyRegisteredError, name if providers.key?(name)

        if from && source.is_a?(Class)
          raise ArgumentError, "You must supply a block when using a provider source"
        end

        if block && source.is_a?(Class)
          raise ArgumentError, "You must supply only a `source:` option or a block, not both"
        end

        return self unless binding.local_variable_get(:if)

        provider =
          if from
            build_provider_from_source(
              name,
              namespace: namespace,
              source: source || name,
              group: from,
              &block
            )
          else
            build_provider(name, namespace: namespace, source: source, &block)
          end

        providers[provider.name] = provider

        self
      end

      # rubocop:enable Metrics/PerceivedComplexity

      # Returns a provider for the given name, if it has already been loaded
      #
      # @api public
      def [](provider_name)
        providers[provider_name]
      end
      alias_method :provider, :[]

      # @api private
      def key?(provider_name)
        providers.key?(provider_name)
      end

      # Returns a provider if it can be found or loaded, otherwise nil
      #
      # @return [Dry::System::Provider, nil]
      #
      # @api private
      def find_and_load_provider(name)
        name = name.to_sym

        if (provider = providers[name])
          return provider
        end

        return if finalized?

        require_provider_file(name)

        providers[name]
      end

      # @api private
      def start_provider_dependency(component)
        if (provider = find_and_load_provider(component.root_key))
          provider.start
        end
      end

      # Returns all provider files within the configured provider_paths.
      #
      # Searches for files in the order of the configured provider_paths. In the case of multiple
      # identically-named boot files within different provider_paths, the file found first will be
      # returned, and other matching files will be discarded.
      #
      # This method is public to allow other tools extending dry-system (like dry-rails)
      # to access a canonical list of real, in-use provider files.
      #
      # @see Container.provider_paths
      #
      # @return [Array<Pathname>]
      # @api public
      def provider_files
        @provider_files ||= provider_paths.each_with_object([[], []]) { |path, (provider_files, loaded)| # rubocop:disable Layout/LineLength
          files = Dir["#{path}/#{RB_GLOB}"].sort

          files.each do |file|
            basename = File.basename(file)

            unless loaded.include?(basename)
              provider_files << Pathname(file)
              loaded << basename
            end
          end
        }.first
      end
      deprecate :boot_files, :provider_files

      # @api private
      def finalize!
        provider_files.each do |path|
          load_provider(path)
        end

        providers.each_value(&:start)

        freeze
      end

      # @!method finalized?
      #   Returns true if the booter has been finalized
      #
      #   @return [Boolean]
      #   @api private
      alias_method :finalized?, :frozen?

      # @api private
      def shutdown
        providers.each_value(&:stop)
        self
      end

      # @api private
      def prepare(provider_name)
        with_provider(provider_name, &:prepare)
        self
      end

      # @api private
      def start(provider_name)
        with_provider(provider_name, &:start)
        self
      end

      # @api private
      def stop(provider_name)
        with_provider(provider_name, &:stop)
        self
      end

      private

      # rubocop:disable Metrics/AbcSize, Metrics/PerceivedComplexity, Layout/LineLength
      # @api private
      def provider_paths
        provider_dirs = container.config.provider_dirs
        bootable_dirs = container.config.bootable_dirs || ["system/boot"]

        if container.config.provider_dirs == ["system/providers"] && \
           provider_dirs.none? { |d| container.root.join(d).exist? } && \
           bootable_dirs.any? { |d| container.root.join(d).exist? }
          Dry::Core::Deprecations.announce(
            "Dry::System::Container.config.bootable_dirs (defaulting to 'system/boot')",
            "Use `Dry::System::Container.config.provider_dirs` (defaulting to 'system/providers') instead",
            tag: "dry-system",
            uplevel: 2
          )

          provider_dirs = bootable_dirs
        end

        provider_dirs.map { |dir|
          dir = Pathname(dir)

          if dir.relative?
            container.root.join(dir)
          else
            dir
          end
        }
      end
      # rubocop:enable Metrics/AbcSize, Metrics/PerceivedComplexity, Layout/LineLength

      def build_provider(name, namespace:, source: nil, &block)
        source_class = source || Provider::Source.for(
          name: name,
          target_container: container,
          &block
        )

        Provider.new(
          name: name,
          namespace: namespace,
          target_container: container,
          source_class: source_class
        )
      end

      def build_provider_from_source(name, source:, group:, namespace:, &block)
        source_class = System.provider_sources.resolve(name: source, group: group)

        Provider.new(
          name: name,
          namespace: namespace,
          target_container: container,
          source_class: source_class,
          &block
        )
      end

      def with_provider(provider_name)
        require_provider_file(provider_name) unless providers.key?(provider_name)

        provider = providers[provider_name]

        raise ProviderNotFoundError, provider_name unless provider

        yield(provider)
      end

      def load_provider(path)
        name = Pathname(path).basename(RB_EXT).to_s.to_sym

        Kernel.require path unless providers.key?(name)

        self
      end

      def require_provider_file(name)
        provider_file = find_provider_file(name)

        Kernel.require provider_file if provider_file
      end

      def find_provider_file(name)
        provider_files.detect { |file| File.basename(file, RB_EXT) == name.to_s }
      end
    end
  end
end
