require 'websocket'
require 'socket'
require File.dirname(__FILE__) + '/errors'

module WebsocketTD
  class Websocket
    IS_WINDOWS   = (RbConfig::CONFIG['host_os'] =~ /mswin|mingw|cygwin/)
    # max length bytes to try to read from a socket per attempt
    @read_buffer = 0
    #true when reading data from a socket
    @active      = false
    #the tread currently being used to read data
    @read_thread = nil
    @auto_pong   = true

    ##
    # +host+:: Host of request. Required if no :url param was provided.
    # +path+:: Path of request. Should start with '/'. Default: '/'
    # +query+:: Query for request. Should be in format "aaa=bbb&ccc=ddd"
    # +secure+:: Defines protocol to use. If true then wss://, otherwise ws://. This option will not change default port - it should be handled by programmer.
    # +port+:: Port of request. Default: nil
    def initialize(host, path, query, secure = false, port = nil)
      if port == nil
        port = secure ? 443 : 80
      end

      @handshake = WebSocket::Handshake::Client.new({
                                                        :host   => host,
                                                        :port   => port,
                                                        :secure => secure,
                                                        :path   => path,
                                                        :query  => query
                                                    })

      @read_buffer = 2048
      @auto_pong   = true
      @closed      = false
      @opened      = false

      @on_open    = lambda {}
      @on_close   = lambda { |message|}
      @on_ping    = lambda { |message|}
      @on_error   = lambda { |error|}
      @on_message = lambda { |message|}

      tcp_socket = TCPSocket.new(host, port)
      if secure
        @socket = OpenSSL::SSL::SSLSocket.new(tcp_socket)
        @socket.connect
      else
        @socket = tcp_socket
      end
      perform_handshake
    end

    attr_reader :read_thread, :read_buffer, :socket, :active, :auto_pong
    attr_writer :read_buffer, :auto_pong, :on_ping, :on_error, :on_message # :on_open, :on_close

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

        begin
          Timeout.timeout(20) do
            Process.wait
          end
        rescue Timeout::Error
          Process.kill 9, pid
          Process.wait pid
        end
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

#protected methods after this
    protected
    def perform_handshake
      @socket.write @handshake.to_s
      buf     = ''
      headers = ''
      reading = true

      while reading
        begin
          if @handshake.finished?
            init_messaging
            #don't stop reading until after init_message to guarantee @read_thread != nil for a successful connection
            reading = false
            @opened =true
            fire_on_open
          else
            #do non blocking reads on headers - 1 byte at a time
            buf.concat(@socket.read_nonblock(1))
            #\r\n\r\n i.e. a blank line, separates headers from body
            idx = buf.index(/\r\n\r\n/m)
            if idx != nil
              headers = buf.slice!(0..idx + 8) #+8 to include the blank line separator
              @handshake << headers            #parse headers

              if @handshake.finished? && !@handshake.valid?
                fire_on_error(ConnectError.new('Server responded with an invalid handshake'))
                fire_on_close() #close if handshake is not valid
              end

              if @handshake.finished?
                @active = true
                buf     = '' #clean up
                headers = ''
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

    #Use one thread to perform blocking read on the socket
    def init_messaging
      if @read_thread == nil
        @read_thread = Thread.new do
          read_loop
        end
      end
    end

    def read_loop
      frame = WebSocket::Frame::Incoming::Client.new(:version => @handshake.version)
      while @active
        if @socket.closed?
          @active = false
          fire_on_close
        else
          begin
            frame << @socket.readpartial(@read_buffer)
            if (message = frame.next) != nil
              #"text", "binary", "ping", "pong" and "close" (according to websocket/base.rb)
              determine_message_type(message)
            end
          rescue EOFError => eof
            fire_on_error(eof)
            fire_on_close
          end
        end
      end
    end

    def determine_message_type(message)
      if message.type == :binary || message.type == :text
        fire_on_message(message)
      elsif message.type == :ping
        if @auto_pong
          send(message.data, :pong)
        end
        fire_on_ping(message)
      elsif message.type == :pong
        fire_on_error(WsProtocolError.new('Invalid type pong received'))
      elsif message.type == :close
        fire_on_close(message)
      else
        fire_on_error(BadMessageTypeError.new("An unknown message type was received #{message.data}"))
      end
    end

    def do_send(data, type=:text)
      frame = WebSocket::Frame::Outgoing::Client.new(:version => @handshake.version, :data => data, :type => type)
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
      @on_ping.call(message) unless @on_ping == nil
    end

    def fire_on_message(message)
      @on_message.call(message) unless @on_message == nil
    end

    def fire_on_open
      @on_open.call() unless @on_open == nil
    end

    def fire_on_error(error)
      @on_error.call(error) unless @on_error == nil
    end

    def fire_on_close(message = nil)
      @active = false
      @closed = true
      @on_close.call(message) unless @on_close == nil
      @socket.close
    end

  end # class
end # module