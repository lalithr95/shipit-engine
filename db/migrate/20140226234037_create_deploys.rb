class CreateDeploys < ActiveRecord::Migration
  def change
    create_table :deploys do |t|
      t.references :repo, index: true, null: false
      t.references :commit, index: true, null: false

      t.timestamps
    end
  end
end
