class CreateCommits < ActiveRecord::Migration
  def change
    create_table :commits do |t|
      t.references :repo, index: true, null: false
      t.string :sha, limit: 40, null: false
      t.string :message, null: false

      t.timestamps
    end
  end
end
