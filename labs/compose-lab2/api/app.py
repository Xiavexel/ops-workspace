from flask import Flask, jsonify
import pymysql
import os

app = Flask(__name__)

def get_db():
    return pymysql.connect(
        host=os.environ.get('DB_HOST', 'db'),
        user=os.environ.get('DB_USER', 'appuser'),
        password=os.environ.get('DB_PASSWORD', 'apppass'),
        database=os.environ.get('DB_NAME', 'appdb'),
        cursorclass=pymysql.cursors.DictCursor
    )

@app.route('/')
def index():
    return jsonify({"service": "api", "status": "ok"})

@app.route('/health')
def health():
    return "OK"

@app.route('/users')
def users():
    conn = get_db()
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT * FROM users")
            return jsonify(cur.fetchall())
    finally:
        conn.close()

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)
