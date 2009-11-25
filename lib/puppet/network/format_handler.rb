require 'yaml'
require 'puppet/network'
require 'puppet/network/format'

module Puppet::Network::FormatHandler
    class FormatError < Puppet::Error; end

    class FormatProtector
        attr_reader :format

        def protect(method, args)
            begin
                Puppet::Network::FormatHandler.format(format).send(method, *args)
            rescue => details
                direction = method.to_s.include?("intern") ? "from" : "to"
                error = FormatError.new("Could not %s %s %s: %s" % [method, direction, format, details])
                error.set_backtrace(details.backtrace)
                raise error
            end
        end

        def initialize(format)
            @format = format
        end

        [:intern, :intern_multiple, :render, :render_multiple, :mime].each do |method|
            define_method(method) do |*args|
                protect(method, args)
            end
        end
    end

    @formats = {}
    def self.create(*args, &block)
        instance = Puppet::Network::Format.new(*args)
        instance.instance_eval(&block) if block_given?

        @formats[instance.name] = instance
        instance
    end

    def self.extended(klass)
        klass.extend(ClassMethods)

        # LAK:NOTE This won't work in 1.9 ('send' won't be able to send
        # private methods, but I don't know how else to do it.
        klass.send(:include, InstanceMethods)
    end

    def self.format(name)
        @formats[name.to_s.downcase.intern]
    end

    # Provide a list of all formats.
    def self.formats
        @formats.keys
    end

    # Return a format capable of handling the provided mime type.
    def self.mime(mimetype)
        mimetype = mimetype.to_s.downcase
        @formats.values.find { |format| format.mime == mimetype }
    end

    # Use a delegator to make sure any exceptions generated by our formats are
    # handled intelligently.
    def self.protected_format(name)
        name = format_to_canonical_name(name)
        @format_protectors ||= {}
        @format_protectors[name] ||= FormatProtector.new(name)
        @format_protectors[name]
    end

    # Return a format name given:
    #  * a format name
    #  * a mime-type
    #  * a format instance
    def self.format_to_canonical_name(format)
        case format
        when Puppet::Network::Format
            out = format
        when %r{\w+/\w+}
            out = mime(format)
        else
            out = format(format)
        end
        raise ArgumentError, "No format match the given format name or mime-type (%s)" % format if out.nil?
        out.name
    end

    module ClassMethods
        def format_handler
            Puppet::Network::FormatHandler
        end

        def convert_from(format, data)
            format_handler.protected_format(format).intern(self, data)
        end

        def convert_from_multiple(format, data)
            format_handler.protected_format(format).intern_multiple(self, data)
        end

        def render_multiple(format, instances)
            format_handler.protected_format(format).render_multiple(instances)
        end

        def default_format
            supported_formats[0]
        end

        def support_format?(name)
            Puppet::Network::FormatHandler.format(name).supported?(self)
        end

        def supported_formats
            result = format_handler.formats.collect { |f| format_handler.format(f) }.find_all { |f| f.supported?(self) }.collect { |f| f.name }.sort do |a, b|
                # It's an inverse sort -- higher weight formats go first.
                format_handler.format(b).weight <=> format_handler.format(a).weight
            end

            result = put_preferred_format_first(result)

            Puppet.debug "#{indirection.name} supports formats: #{result.sort.join(' ')}; using #{result.first}"

            result
        end

        private

        def put_preferred_format_first(list)
            preferred_format = Puppet.settings[:preferred_serialization_format].to_sym
            if list.include?(preferred_format)
                list.delete(preferred_format)
                list.unshift(preferred_format)
            else
                Puppet.warning "Value of 'preferred_serialization_format' (#{preferred_format}) is invalid for #{indirection.name}, using default (#{list.first})"
            end
            list
        end
    end

    module InstanceMethods
        def render(format = nil)
            format ||= self.class.default_format

            Puppet::Network::FormatHandler.protected_format(format).render(self)
        end

        def mime(format = nil)
            format ||= self.class.default_format

            Puppet::Network::FormatHandler.protected_format(format).mime
        end

        def support_format?(name)
            self.class.support_format?(name)
        end
    end
end

require 'puppet/network/formats'
