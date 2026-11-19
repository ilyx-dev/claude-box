# claude-box / docker-ro: Docker API хоста только для чтения (фильтр на Python, без сторонних зависимостей)
FROM python:3.12-alpine
COPY docker-ro.py /app/docker-ro.py
USER root
EXPOSE 2375
CMD ["python3", "-u", "/app/docker-ro.py"]
