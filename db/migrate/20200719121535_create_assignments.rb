class CreateAssignments < ActiveRecord::Migration[5.2]
  def change
    create_table :assignments do |t|
      t.integer :user_id
      t.string :title
      t.datetime :limit
      t.boolean :complete
      t.timestamps null: false
    end
  end
end
