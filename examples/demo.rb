class Demo
  require '../lib/websocket_td'

  def initialize

    # Alternative version:
    # client = WebsocketTD::Websocket.new host: 'websocket.datasift.com', path: '/multi', query: 'username=zcourts&api_key=91207449dd5b89a4ff38879a770975bf', reconnect: true
    client = WebsocketTD::Websocket.new('websocket.datasift.com', '/multi', 'username=zcourts&api_key=91207449dd5b89a4ff38879a770975bf')

    puts 'I continued'

    client.on_message = lambda { |message| puts "message: #{message.data}" }

    client.on_open  = lambda {
      puts 'opened'
      client.send("{ \"action\":\"subscribe\",\"hash\":\"1f678ba99fbcad0b572011b390cf5124\"}")
    }
    client.on_close = lambda { |m| puts "Closed #{m}" }
    while true
      puts 'subscribing'
      if client.active
        client.send("{ \"action\":\"subscribe\",\"hash\":\"1f678ba99fbcad0b572011b390cf5124\"}")
      end
      sleep(1)
    end
    #if main thread finishes then the process exists...don't let that happen
    client.read_thread.join
  end
end
Demo.new
