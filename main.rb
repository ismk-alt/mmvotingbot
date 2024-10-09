require 'sinatra'
require 'json'
require 'net/http'
require 'sqlite3'
require 'thread'

# Initialize the database (SQLite)
DB = SQLite3::Database.new 'voting_bot.db'
DB.results_as_hash = true

# Create tables if they do not exist
DB.execute <<-SQL
  CREATE TABLE IF NOT EXISTS votes (
    item TEXT,
    user TEXT,
    voter TEXT,
    PRIMARY KEY (item, voter)
  );
SQL

DB.execute <<-SQL
  CREATE TABLE IF NOT EXISTS voters_log (
    voter TEXT,
    item TEXT,
    PRIMARY KEY (voter, item)
  );
SQL

# Добавляем таблицу для хранения автора текущего голосования
DB.execute <<-SQL
  CREATE TABLE IF NOT EXISTS current_vote (
    author TEXT
  );
SQL

# URL and tokens (use environment variables for security)
INCOMING_WEBHOOK_URL = ENV['INCOMING_WEBHOOK_URL']
OUTGOING_WEBHOOK_TOKEN = ENV['OUTGOING_WEBHOOK_TOKEN']
BOT_ACCESS_TOKEN = ENV['BOT_ACCESS_TOKEN']
ADMIN_USERNAME = ENV['ADMIN_USERNAME'] || 'admin'
BOT_USERNAME = ENV['BOT_USERNAME'] || 'bot_username' # Добавляем имя пользователя бота

# Добавляем канал по умолчанию
DEFAULT_CHANNEL_ID = ENV['DEFAULT_CHANNEL_ID'] || 'your_default_channel_id'

# Mutex for thread safety
$mutex = Mutex.new

# Sinatra route for handling voting
post '/vote' do
  begin
    request_payload = JSON.parse(request.body.read)

    # Log received webhook request
    puts "Webhook received: #{request_payload}"

    # Validate outgoing webhook token
    token = request_payload['token']&.strip
    expected_token = OUTGOING_WEBHOOK_TOKEN&.strip

    unless token && token == expected_token
      puts "Invalid token: received='#{token}', expected='#{expected_token}'"
      halt 403, 'Invalid token'
    end

    # Extract command and user information
    command = request_payload['text']&.strip
    user = request_payload['user_name']
    action = request_payload.dig('context', 'action')
    item = request_payload.dig('context', 'item')
    selected_option = request_payload.dig('data', 'values', 'employee_select')
    channel_id = request_payload['channel_id']

    if action == 'vote'
      selected_user = selected_option
      response_message = register_vote(user, item, selected_user)
      send_message_to_mattermost(response_message, nil, channel_id) if response_message
    else
      if command.nil? || command.empty?
        halt 400, 'Invalid command format. Command text cannot be empty.'
      end

      response_messages = handle_command(command, user, channel_id)

      if response_messages
        parent_message_id = send_message_to_mattermost(response_messages.shift, nil, channel_id)
        response_messages.each do |msg|
          send_message_to_mattermost(msg, parent_message_id, channel_id)
        end
      end
    end

    status 200
  rescue JSON::ParserError => e
    puts "JSON parsing error: #{e.message}"
    halt 400, 'Invalid JSON format'
  rescue StandardError => e
    puts "An error occurred: #{e.message}"
    halt 500, 'Internal Server Error'
  end
end

# Handle the received command
def handle_command(command, user, channel_id)
  case command
  when /^!start_vote\s*(.*)/
    items = command.split("\n")[1..-1]
    if items.empty?
      return ['Ошибка: Вы должны предоставить хотя бы одну номинацию для голосования.']
    end
    start_vote(items, user, channel_id)
    nil
  when '!end_vote'
    end_vote
  else
    ['Неизвестная команда. Пожалуйста, используйте !start_vote или !end_vote.']
  end
end

# Start a new vote
def start_vote(items, user, channel_id)
  $mutex.synchronize do
    DB.execute('DELETE FROM votes') # Clear previous votes
    DB.execute('DELETE FROM voters_log') # Clear previous voters log
    DB.execute('DELETE FROM current_vote') # Clear previous vote author
    DB.execute('INSERT INTO current_vote (author) VALUES (?)', [user]) # Store the author
  end

  # Получаем список сотрудников
  employee_options = get_employee_options

  # Создаем интерактивные сообщения для каждой номинации
  items.each do |item|
    message = {
      "channel_id" => channel_id,
      "message" => "",
      "props" => {
        "attachments" => [
          {
            "text" => "#{item}",
            "actions" => [
              {
                "name" => "employee_select",
                "type" => "select",
                "data_source" => "users",
                "options" => employee_options,
                "integration" => {
                  "url" => INCOMING_WEBHOOK_URL,
                  "context" => {
                    "action" => "vote",
                    "item" => item
                  }
                }
              }
            ]
          }
        ]
      }
    }

    send_message_via_api(message, channel_id)
  end
end

# Register a user's vote
def register_vote(voter, item, selected_user)
  response_message = nil
  $mutex.synchronize do
    already_voted = DB.get_first_row('SELECT * FROM voters_log WHERE voter = ? AND item = ?', [voter, item])

    if !already_voted
      if selected_user.nil? || selected_user.empty?
        response_message = "Вы не выбрали сотрудника для номинации \"#{item}\"."
      else
        DB.execute('INSERT INTO votes (item, user, voter) VALUES (?, ?, ?)', [item, selected_user, voter])
        DB.execute('INSERT INTO voters_log (voter, item) VALUES (?, ?)', [voter, item])
        response_message = "Ваш голос за \"#{selected_user}\" в номинации \"#{item}\" был засчитан!"
      end
    else
      response_message = "Вы уже голосовали в номинации \"#{item}\"!"
    end

    # Отправляем результаты автору
    send_current_results_to_author
  end
  response_message
end

# Отправка текущих результатов автору
def send_current_results_to_author
  author_row = DB.get_first_row('SELECT author FROM current_vote')
  return unless author_row

  author = author_row['author']
  results = DB.execute('SELECT item, user, COUNT(*) as count FROM votes GROUP BY item, user')

  results_message = "Текущие результаты голосования:\n"
  items = results.group_by { |row| row['item'] }
  items.each do |item_name, votes|
    results_message += "#{item_name}:\n"
    votes.each do |vote|
      results_message += "- #{vote['user']}: #{vote['count']} голосов\n"
    end
  end

  send_direct_message_to_user(author, results_message)
end

# End the voting process and send results to admin
def end_vote
  results_messages = []
  $mutex.synchronize do
    results = DB.execute('SELECT item, user, COUNT(*) as count FROM votes GROUP BY item, user')
    results_messages << "Голосование завершено. Результаты:"
    items = results.group_by { |row| row['item'] }
    items.each do |item_name, votes|
      results_messages << "#{item_name}:"
      votes.each do |vote|
        results_messages << "- #{vote['user']}: #{vote['count']} голосов"
      end
    end

    # Clear votes and voters log after ending
    DB.execute('DELETE FROM votes')
    DB.execute('DELETE FROM voters_log')
    DB.execute('DELETE FROM current_vote') # Очищаем текущего автора
  end
  send_direct_message_to_admin(results_messages)
  results_messages
end

# Send a direct message to the admin
def send_direct_message_to_admin(messages)
  messages.each do |message|
    send_direct_message_to_user(ADMIN_USERNAME, message)
  end
end

# Отправляем личное сообщение пользователю
def send_direct_message_to_user(username, message)
  uri = URI("http://localhost:8065/api/v4/posts")

  header = {
    'Content-Type' => 'application/json',
    'Authorization' => "Bearer #{BOT_ACCESS_TOKEN}"
  }
  body = {
    channel_id: get_direct_channel_id(username),
    message: message
  }.to_json

  send_post_request(uri, header, body)
end

# Get direct channel ID for a given username
def get_direct_channel_id(username)
  uri = URI("http://localhost:8065/api/v4/channels/direct")

  header = {
    'Content-Type' => 'application/json',
    'Authorization' => "Bearer #{BOT_ACCESS_TOKEN}"
  }
  body = [
    get_user_id(BOT_USERNAME),
    get_user_id(username)
  ].to_json

  response = send_post_request(uri, header, body)
  channel = JSON.parse(response.body)
  channel['id']
end

# Get user ID by username
def get_user_id(username)
  uri = URI("http://localhost:8065/api/v4/users/username/#{username}")

  header = {
    'Content-Type' => 'application/json',
    'Authorization' => "Bearer #{BOT_ACCESS_TOKEN}"
  }

  response = send_get_request(uri, header)
  user = JSON.parse(response.body)
  user['id']
end

# Send a message to Mattermost
def send_message_to_mattermost(message, root_id = nil, channel_id = nil)
  if message.is_a?(Hash) && (message.key?('attachments') || message.key?(:attachments))
    send_message_via_api(message, channel_id || DEFAULT_CHANNEL_ID, root_id)
  else
    uri = URI(INCOMING_WEBHOOK_URL)

    header = {
      'Content-Type' => 'application/json'
    }
    body = message.is_a?(String) ? { text: message, root_id: root_id }.to_json : message.merge({ root_id: root_id }).to_json

    response = send_post_request(uri, header, body)
    if response.code == '200'
      JSON.parse(response.body)['id'] rescue nil
    else
      raise "Failed to send message to Mattermost: #{response.body}"
    end
  end
end

# Отправка сообщения с помощью API (для интерактивных сообщений)
def send_message_via_api(message, channel_id, root_id = nil)
  uri = URI("http://localhost:8065/api/v4/posts")

  header = {
    'Content-Type' => 'application/json',
    'Authorization' => "Bearer #{BOT_ACCESS_TOKEN}"
  }

  body = {
    channel_id: channel_id,
    root_id: root_id,
    message: message['message'] || '',
    props: message['props'] || {}
  }.to_json

  response = send_post_request(uri, header, body)
  if response.code == '201'
    JSON.parse(response.body)['id']
  else
    raise "Failed to send message via API: #{response.body}"
  end
end

# Helper methods for HTTP requests
def send_post_request(uri, header, body)
  http = Net::HTTP.new(uri.host, uri.port)
  # Убираем использование SSL, так как сервер работает по HTTP
  # http.use_ssl = (uri.scheme == 'https')
  request = Net::HTTP::Post.new(uri.request_uri, header)
  request.body = body
  response = http.request(request)
  puts "Response from Mattermost: #{response.code} - #{response.body}"
  response
end

# Helper method to send GET request
def send_get_request(uri, header)
  http = Net::HTTP.new(uri.host, uri.port)
  # Убираем использование SSL, так как сервер работает по HTTP
  # http.use_ssl = (uri.scheme == 'https')
  request = Net::HTTP::Get.new(uri.request_uri, header)
  response = http.request(request)
  puts "Response from Mattermost: #{response.code} - #{response.body}"
  response
end

# Получение списка сотрудников для голосования
def get_employee_options
  # Здесь вы должны реализовать логику получения списка сотрудников.
  # Например, вы можете получить список пользователей через API Mattermost.
  # Для упрощения примера используем статический список:

  [
    { "text" => "Иван Иванов", "value" => "Иван Иванов" },
    { "text" => "Мария Петрова", "value" => "Мария Петрова" },
    { "text" => "Петр Сидоров", "value" => "Петр Сидоров" }
    # Добавьте остальных сотрудников
  ]
end

# Запуск Sinatra приложения
set :port, ENV.fetch('PORT', 4567)
# Устанавливаем привязку к 0.0.0.0, чтобы приложение было доступно извне (если необходимо)
set :bind, '0.0.0.0'
