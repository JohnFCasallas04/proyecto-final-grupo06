# Usa la imagen oficial de Python
FROM python:3.12

# Establece el directorio de trabajo en el contenedor
WORKDIR /app

# Copia los archivos de la aplicación
COPY app.py requirements.txt ./

# Instala las dependencias
RUN pip install --no-cache-dir -r requirements.txt

# Expone el puerto en el que corre Flask
EXPOSE 5001

# Comando para ejecutar la aplicación
CMD ["python", "-u", "app.py"]