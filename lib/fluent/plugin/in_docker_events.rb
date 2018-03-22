require 'fluent/input'

module Fluent
    class DockerEventStreamInput < Input
        Fluent::Plugin.register_input('docker_events', self)

        config_param :tag, :string, :default => "docker"
        config_param :events, :string, :default => []
        config_param :timeout, :integer, :default => 5

        # Define `router` method of v0.12 to support v0.10 or earlier
        unless method_defined?(:router)
            define_method("router") { Fluent::Engine }
        end

        def initialize
            super
            require 'docker'
        end

        def configure(conf)
            super

            if @timeout == nil || @timeout <= 0
                raise Fluent::ConfigError "Param 'timeout' has unsupported value '#{@timeout}'"
            end
            if @events == nil || @events == []
                raise Fluent::ConfigError "Param 'events' has unsupported value '#{@events}'"
            end

            @events = @events.split(',').map {|event| event.strip }
            Docker.options[:read_timeout] = @timeout
            @last_received = 0
            @num_of_events = 0

            log.debug "Configuration:\n", "Event list:", @events, "\n", "Timeout: ", @timeout
        end

        def start
            super
            @running = true
            @thread = Thread.new(&method(:run))
        end

        def shutdown
            @running = false
            @thread.join
            log.info "Shutting down, number of events processed: #{@num_of_events}"
        end

        def run
            while @running
                log.debug "Entered 'while' loop. @running is '#{@running}', @last_received is '#{@last_received}'"
                begin
                    Docker::Event.stream(@last_received) do |event|
                        log.debug "Received event #{event}. @running is '#{@running}', @last_received is '#{@last_received}'"
                        if @events.include?(event.action)
                            @last_received = event.timeNano
                            @num_of_events += 1
                            emit(event)
                        end
                    end
                rescue Docker::Error::TimeoutError => e
                    log.error e.class, ": ", e
                rescue Exception => e
                    log.error e.class, ": ", e
                end
            end
        end

        def emit(r)
            begin
                record = {
                    "id" => r.id,
                    "action" => r.action,
                    "status" => r.status,
                    "type" => r.type,
                    "time" => r.time
                }
                _container = Docker::Container.get(r.id)
                if _container
                    record["container"] = {
                        "state" => _container.info["State"],
                        "name" => _container.info["Name"].gsub(/^\//, ''),
                    }
                    _image = Docker::Image.get(_container.info["Image"])
                    if _image
                        record["container"]["image"] = _image.info["RepoTags"]
                    end
                end
                event = {
                    "event" => record
                }
                router.emit(@tag, Time.now.to_i, event)
            rescue => e
                log.error e.class, ": ", e
            end
        end
    end
end
