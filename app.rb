require 'bundler/setup'
Bundler.require
require 'sinatra/reloader' if development?
require './models.rb'
require 'line/bot'

# -------------------------------
# 共通処理
# -------------------------------

# LINEログイン設定
def client
  @client ||= Line::Bot::Client.new { |config|
    config.channel_secret = ENV["LINE_CHANNEL_SECRET"]
    config.channel_token = ENV["LINE_CHANNEL_TOKEN"]
  }
end

# ユーザーがいるかどうかを調べる。いなかったらUserに新しくつくる
def checkUser(line_uid)
  begin
    id = User.find_by(line_uid: line_uid).id
  rescue => exception
    id = nil
  end
  unless id.nil?
    return id
  else
    User.create({
      line_uid: line_uid
    })
    return User.find_by(line_uid: line_uid).id
  end
  p 'complete checkUser'
end

# -------------------------------
# ここから 定期実行
# -------------------------------

# 課題は毎時0-5に判断
# 時間割は授業開始時間ごとに実行
get '/schedule' do
  # 時間を取得
  time = DateTime.now
  timeW = time.wday
  timeM = time.minute.to_i

  # 課題確認の定期実行（毎時0分から5分までの間に実行）
  if 0 <= timeM && timeM <= 5
    checkUsers = User.all
    checkUsers.each do |user|
      p 'cheak user'
      judgLimitAssignments(user.id)
    end
  end

  erb :index
end

# LINEに配信メッセージを送信（テキストのみ）
def sendMessageToLine(line_uid,sendText)
  uri = URI.parse("https://api.line.me/v2/bot/message/multicast")
  request = Net::HTTP::Post.new(uri)
  request.content_type = "application/json"
  request["Authorization"] = "Bearer {" + ENV["LINE_CHANNEL_TOKEN"] + "}"
  request.body = JSON.dump({
    "to" => [
      line_uid
    ],
    "messages" => [
      {
        "type" => "text",
        "text" => sendText
      }
    ]
  })
  req_options = {
    use_ssl: uri.scheme == "https",
  }
  response = Net::HTTP.start(uri.hostname, uri.port, req_options) do |http|
    http.request(request)
  end
end

# 課題--------------

# 指定されたユーザーに1-2時間以降に締め切りがある科目であるか判断→あれば→createLimitAssignmentsを使う
def judgLimitAssignments(user_id)
  # 現在時刻の2時間後を判断基準とする
  judgDatetime = DateTime.now + Rational(2, 24)
  p '判断時間:' + judgDatetime.to_s + ' / USER_ID:' + user_id.to_s

  # 該当ユーザーの課題一覧を取得する
  assignments = Assignment.where(user_id: user_id).where(complete: false)

  # 判断基準の時間より超えているかを確認→超えていた場合は、limitAssignmentsに格納
  limitAssignments = assignments.map do |assignment|
    unless assignment.limit.to_s.empty?
      limit = assignment.limit.to_s
      limitA = DateTime.parse(limit.slice!(0,19) + '+09:00')
      if limitA < judgDatetime
        assignment
      end
    end
  end.compact

  # なんらかのテキストが挿入された場合は、ライン送信を実行する
  unless limitAssignments.empty?
    line_uid = User.find(user_id).line_uid
    sendText = createLimitAssignments(limitAssignments)
    sendMessageToLine(line_uid, sendText)
  else
    p '課題チェック完了'
  end
end

# 課題用のメッセージを作成(returnで文字列を返却)
def createLimitAssignments(limitAssignments)
  limitAssignmentsText = "🚨〆切まであと1-2時間🚨"
  limitAssignments.each do |assignment|
    unless assignment.limit.to_s.nil?
      limit = assignment.limit.to_s
      limit = limit.slice(0..15)
    else
      limit = "期限なし"
    end
    limitAssignmentsText = limitAssignmentsText.to_s + "\n" + assignment.id.to_s + ":" + assignment.title.to_s + "("+ limit +")"
  end

  return limitAssignmentsText
end

# -------------------------------
# メッセージアプリ関連
# -------------------------------

# メッセージAPIのメッセージ返信部分
post '/callback' do
  body = request.body.read

  signature = request.env['HTTP_X_LINE_SIGNATURE']
  unless client.validate_signature(body, signature)
    error 400 do 'Bad Request' end
  end

  events = client.parse_events_from(body)

  events.each { |event|
    case event
    when Line::Bot::Event::Message
      case event.type
      # メッセージがきた場合
      when Line::Bot::Event::MessageType::Text
        message = event.message["text"]
        line_uid = event["source"]["userId"]
        id = checkUser(line_uid)
        # メッセージに「課題一覧」と来た場合
        if message.include?("課題一覧")
          @assignments = Assignment.where(user_id: id).where(complete: "false").order(limit: "ASC")
          assignmentsAll = "【課題一覧】\n管理番号:課題タイトル(〆切日)"
          @assignments.each do |assignment|
            unless assignment.limit.nil?
              limit = assignment.limit.to_s
              limit = limit.slice(0..15)
            else
              limit = "期限なし"
            end
            assignmentsAll = assignmentsAll.to_s + "\n" + assignment.id.to_s + ":" + assignment.title.to_s + "("+ limit +")"
          end
          client.reply_message(event['replyToken'], assignmentsView(assignmentsAll))

        # メッセージに「課題 title」ときた場合
        elsif message.include?("課題")
          user_id_b = Base64.encode64(id.to_s).chop
          content = message.slice!(3,(message.size - 3))
          client.reply_message(event['replyToken'], checkAssignment(content))

        # メッセージに「完了 assignment_number」ときた場合
        elsif message.include?("完了")
          contentText = message.slice!(3,(message.size - 3))
          begin
            completeContent = Assignment.where(user_id: id).where(complete: "false").find(contentText)
          rescue => exception
            contentText = nil
          end
          unless completeContent.nil?
            completeContent.update({
              complete: "true"
            })
            client.reply_message(event['replyToken'], completeAssignment(completeContent.title))
          else
            client.reply_message(event['replyToken'], AssignmentError())
          end

        # メッセージに「取消 assignment_number」ときた場合
        elsif message.include?("取消")
          contentText = message.slice!(3,(message.size - 3))
          begin
            completeContent = Assignment.where(user_id: id).where(complete: "true").find(contentText)
          rescue => exception
            contentText = nil
          end
          unless completeContent.nil?
            completeContent.update({
              complete: "false"
            })
            client.reply_message(event['replyToken'], revivalAssignment(completeContent.title))
          else
            client.reply_message(event['replyToken'], AssignmentError())
          end

        # エラーメッセージを返す
        else
          client.reply_message(event['replyToken'], errorMessage)
        end
      end
      # Postbackがきた場合
      when Line::Bot::Event::Postback
      content = event["postback"]["data"]
      line_uid = event["source"]["userId"]
      id = checkUser(line_uid)
      if event["postback"]["params"].present?
        limit = event["postback"]["params"]["datetime"]
        Assignment.create({
          user_id: id,
          title: content,
          limit: limit.to_datetime,
          complete: "false"
        })
        client.reply_message(event['replyToken'], newAssignmentWithDate(content,limit))
      else
        Assignment.create({
          user_id: id,
          title: content,
          complete: "false"
        })
        client.reply_message(event['replyToken'], newAssignment(content))
      end
    end
  }
  # head :ok
end

# -------------------------------
# メッセージ送信テンプレート
# -------------------------------
private

# サンプルメッセージ
def sampleText(inputText)
  {
    "type": "text",
    "text": inputText
  }
end

# 課題登録確認メッセージ
def checkAssignment(contentText)
  {
    "type": "template",
    "altText": "スマホで確認してください。",
    "template": {
      "type": "buttons",
      "actions": [
        {
          "type": "postback",
          "label": "登録する（〆切日時なし）",
          "data": contentText
        },
        {
          "type": "datetimepicker",
          "label": "〆切日時を追加する",
          "data": contentText,
          "mode": "datetime",
        }
      ],
      "title": "課題登録確認",
      "text": contentText
    }
  }
end

# 課題登録完了メッセージ（〆切あり）
def newAssignmentWithDate(contentText,limit)
  {
    "type": "text",
    "text": "【登録完了】\n課題タイトル：" + contentText + "\n〆切日時：" + limit
  }
end

# 課題登録完了メッセージ（〆切なし）
def newAssignment(contentText)
  {
    "type": "text",
    "text": "【登録完了】\n課題タイトル：" + contentText
  }
end

# 課題復元確認メッセージ
def revivalAssignment(contentText)
  {
    "type": "text",
    "text": "課題を復元しました！(≧∇≦)o\n\n復元した課題：" + contentText
  }
end

# 課題完了確認メッセージ
def completeAssignment(contentText)
  {
    "type": "text",
    "text": "課題完了！お疲れ様でした！(≧∇≦)o\n\n完了した課題：" + contentText
  }
end

# 課題系のエラーメッセージ
def AssignmentError()
  {
    "type": "text",
    "text": "ごめんなさい m(._.*)m\n入力された課題を確認できませんでした。"
  }
end

# 課題一覧、応答メッセージ
def assignmentsView(assignmentsAll)
  {
    "type": "text",
    "text": assignmentsAll
  }
end

# エラーメッセージ
def errorMessage
  {
    "type": "text",
    "text": "ごめんなさい m(._.*)m\n入力された内容がわかりませんでした。\n以下の形式でもう一度入力してみてください( •̀人•́ )\n------課題の一覧を見る場合\n例：課題一覧\n\n------課題を追加する場合\n例：課題 数学P13-15\n\n------課題が完了した場合\n完了 課題番号\n例：1\n※課題の完了は、課題一覧の管理番号を入力するかタイトルの入力で実行することができます。"
  }
end