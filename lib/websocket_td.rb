require 'websocket'
require 'socket'
require File.dirname(__FILE__) + '/errors'

module WebsocketTD
  class Websocket
    IS_WINDOWS   = (RbConfig::CONFIG['host_os'] =~ /mswin|mingw|cygwin/)

    DEFAULT_OPTS = {
      auto_pong: true,
      read_buffer_size: 2048,
      reconnect: false,
      secure: false,
      retry_time: 1
    }

    attr_reader :socket, :read_thread,  :protocol_version
    attr_accessor :auto_pong, :on_ping, :on_error, :on_message

    ##
    # +host+:: Host of request. Required if no :url param was provided.
    # +path+:: Path of request. Should start with '/'. Default: '/'
    # +query+:: Query for request. Should be in format "aaa=bbb&ccc=ddd"
    # +secure+:: Defines protocol to use. If true then wss://, otherwise ws://. This option will not change default port - it should be handled by programmer.
    # +port+:: Port of request. Default: nil
    # +opts+:: Additional options:
    #   :reconnect - if true, it will try to reconnect
    #   :retry_time - how often should retries happen when reconnecting [default = 1s]
    # Alternatively it can be called with a single hash where key names as symbols are the same as param names
    def initialize(host, path = '', query = '', secure = false, port = nil, opts={})

      # Initializing with a single hash
      if host.kind_of? Hash
        opts = host
        @host    = opts.delete :host
        @port    = opts.delete :port
        @path    = opts.delete(:path).to_s
        @query   = opts.delete(:query).to_s
        @secure  = opts.delete :secure
      else # initializing with a params list
        @host   = host
        @port   = port
        @secure = secure
        @path   = path
        @query  = query
      end

      @opts = DEFAULT_OPTS.merge opts
      @port ||= @secure ? 443 : 80

      @auto_pong   = opts[:auto_pong]
      @closed      = false
      @opened      = false

      @on_open    = lambda {}
      @on_close   = lambda { |message|}
      @on_ping    = lambda { |message|}
      @on_error   = lambda { |error|}
      @on_message = lambda { |message|}

      connect
    end

    ##
    #Send the data given by the data param
    #if running on a posix system this uses Ruby's fork method to send
    #if on windows fork won't be attempted.
    #+data+:: the data to send
    #+type+:: :text or :binary, defaults to :text
    def send(data, type = :text)
      if IS_WINDOWS
        do_send(data, type) #fork not supported on windows
      else
        pid = fork do
          do_send(data, type)
        end
        Process.detach(pid)
      end
    end

    ##
    #sets a Proc to be executed when the connection is opened and ready for writing
    #+p+:: the Proc to execute
    def on_open=(p)
      @on_open = p
      if @opened
        fire_on_open
      end
    end

    ##
    #sets a Proc to be executed when the connection is closed and ready for writing
    #+p+:: the Proc to execute
    def on_close=(p)
      @on_close = p
      if @closed
        fire_on_close
      end
    end

    protected

    def connect
      tcp_socket = TCPSocket.new(@host, @port)
      if @secure
        @socket = OpenSSL::SSL::SSLSocket.new(tcp_socket)
        @socket.connect
      else
        @socket = tcp_socket
      end
      perform_handshake
    end

    def reconnect
      @closed = false
      @opened = false

      until @opened
        begin
          connect
        rescue Errno::ECONNREFUSED
          sleep @opts[:retry_time]
        rescue Exception => e
          fire_on_error e
        end
      end
    end

    def perform_handshake
      handshake = WebSocket::Handshake::Client.new({
        :host   => @host,
        :port   => @port,
        :secure => @secure,
        :path   => @path,
        :query  => @query
      })

      @socket.write handshake.to_s
      buf = ''

      loop do
        begin
          if handshake.finished?
            @protocol_version = handshake.version
            @active = true
            @opened = true
            init_messaging
            fire_on_open
            break
          else
            # do non blocking reads on headers - 1 byte at a time
            buf.concat(@socket.read_nonblock(1))
            # \r\n\r\n i.e. a blank line, separates headers from body
            if idx = buf.index(/\r\n\r\n/m)
              handshake << buf # parse headers

              if handshake.finished? && !handshake.valid?
                fire_on_error(ConnectError.new('Server responded with an invalid handshake'))
                fire_on_close #close if handshake is not valid
                break
              end
            end
          end
        rescue IO::WaitReadable
          # ignored
        rescue IO::WaitWritable
          # ignored
        end
      end
    end

    # Use one thread to perform blocking read on the socket
    def init_messaging
      @read_thread ||= Thread.new { read_loop }
    end

    def read_loop
      frame = WebSocket::Frame::Incoming::Client.new(:version => @protocol_version)
      while @active
        begin
          frame << @socket.readpartial(@opts[:read_buffer_size])
          while message = frame.next
            #"text", "binary", "ping", "pong" and "close" (according to websocket/base.rb)
            determine_message_type(message)
          end
          fire_on_error WsProtocolError.new(frame.error) if frame.error?
        rescue Exception => e
          fire_on_error(e)
          if @socket.closed? || @socket.eof?
            fire_on_close
            @read_thread = nil
            break
          end
        end
      end
    end

    def determine_message_type(message)
      case message.type
      when :binary, :text
        fire_on_message(message)
      when :ping
        send(message.data, :pong) if @auto_pong
        fire_on_ping(message)
      when :pong
        fire_on_error(WsProtocolError.new('Invalid type pong received'))
      when :close
        fire_on_close(message)
      else
        fire_on_error(BadMessageTypeError.new("An unknown message type was received #{message.data}"))
      end
    end

    def do_send(data, type=:text)
      frame = WebSocket::Frame::Outgoing::Client.new(:version => @protocol_version, :data => data, :type => type)
      begin
        @socket.write frame #_nonblock
        @socket.flush
      rescue Errno::EPIPE => ce
        fire_on_error(ce)
        fire_on_close
      rescue Exception => e
        fire_on_error(e)
      end
    end

    def fire_on_ping(message)
      @on_ping.call(message) if @on_ping
    end

    def fire_on_message(message)
      @on_message.call(message) if @on_message
    end

    def fire_on_open
      @on_open.call() if @on_open
    end

    def fire_on_error(error)
      @on_error.call(error) if @on_error
    end

    def fire_on_close(message = nil)
      @active = false
      @closed = true
      @on_close.call(message) if @on_close
      @socket.close unless @socket.closed?

      reconnect if @opts[:reconnect]
    end

  end # class
end # module
