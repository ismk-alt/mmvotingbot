# models/vote_model.rb
require 'sqlite3'
require 'thread'

class VoteModel
  # Инициализация базы данных и настройка
  DB = SQLite3::Database.new 'voting_bot.db'
  DB.results_as_hash = true
  $mutex = Mutex.new

  # Создание таблиц с правильной структурой, если они не существуют
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

  DB.execute <<-SQL
    CREATE TABLE IF NOT EXISTS current_vote (
      author TEXT
    );
  SQL

  # Создание таблицы для хранения контекста голосования (например, выбранный сотрудник)
  DB.execute <<-SQL
    CREATE TABLE IF NOT EXISTS vote_context (
      post_id TEXT PRIMARY KEY,
      selected_user TEXT
    );
  SQL

  # Метод для начала нового голосования с указанными номинациями
  def self.start_vote(items, user, channel_id)
    $mutex.synchronize do
      DB.execute('DELETE FROM votes')
      DB.execute('DELETE FROM voters_log')
      DB.execute('DELETE FROM current_vote')
      DB.execute('INSERT INTO current_vote (author) VALUES (?)', [user])
    end

    # Отправляем сообщение для каждой номинации
    items.each do |item|
      MattermostApi.send_vote_message(item, channel_id)
    end
  end

  # Метод для завершения голосования и получения результатов
  def self.end_vote
    results = DB.execute('SELECT item, user, COUNT(*) as count FROM votes GROUP BY item, user')
    $mutex.synchronize do
      DB.execute('DELETE FROM votes')
      DB.execute('DELETE FROM voters_log')
      DB.execute('DELETE FROM current_vote')
    end
    results
  end

  # Метод для регистрации голоса пользователя
  def self.register_vote(voter, item, selected_user)
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
    end
    response_message
  end

  # Метод для сохранения выбранного сотрудника для поста голосования
  def self.save_selected_user(post_id, selected_user)
    $mutex.synchronize do
      DB.execute('INSERT OR REPLACE INTO vote_context (post_id, selected_user) VALUES (?, ?)', [post_id, selected_user])
    end
  end

  # Метод для получения сохраненного выбранного сотрудника по посту
  def self.get_selected_user(post_id)
    row = DB.get_first_row('SELECT selected_user FROM vote_context WHERE post_id = ?', [post_id])
    row ? row['selected_user'] : nil
  end

  # Метод для получения списка сотрудников (здесь используется статический пример)
  def self.get_employee_options
    [
      { "text" => "Иван Иванов", "value" => "Иван Иванов" },
      { "text" => "Мария Петрова", "value" => "Мария Петрова" },
      { "text" => "Петр Сидоров", "value" => "Петр Сидоров" }
    ]
  end
end
