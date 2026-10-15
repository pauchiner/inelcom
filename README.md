# Cisco Packet Tracer 9.0.0 — LliureX

Script de instalación automatizada de **Cisco Packet Tracer 9.0.0** en sistemas LliureX.

El instalador automatiza la preparación del sistema, la activación temporal de los repositorios de Ubuntu Jammy, la instalación de dependencias, la descarga del paquete DEB, la instalación del icono y la creación del acceso directo en el menú de aplicaciones.

## Características

- Instalación automatizada de Cisco Packet Tracer 9.0.0.
- Activación temporal de los repositorios de Ubuntu Jammy.
- Restauración de la configuración temporal de APT al finalizar.
- Comprobación de errores durante la descarga y la instalación.
- Resolución de dependencias mediante APT.
- Instalación del icono de la aplicación.
- Creación del acceso directo en el menú de aplicaciones.
- Posibilidad de ejecutar el instalador de forma remota mediante SSH y ClusterSSH.

## Requisitos

- LliureX con acceso a Internet.
- Permisos de `sudo`.
- Herramientas `curl`, `dpkg`, `dpkg-deb`, `apt-get` e `install`.
- Acceso a los repositorios de Ubuntu Jammy.

## Instalación

Abre una terminal y ejecuta los siguientes comandos:

```bash
curl -o setup.sh https://raw.githubusercontent.com/pauchiner/packet-tracer/refs/heads/main/setup.sh
chmod +x setup.sh
./setup.sh
```

El instalador solicitará la contraseña de `sudo` cuando sea necesario.
También pedirá aceptar el EULA durante el proceso de instalación (Esto solo ocurre durante la instalación
después estará disponible para todos los usuarios con la EULA ya activada)

Una vez finalizado, podrás abrir Packet Tracer desde el menú de aplicaciones, en la categoría **Educación**, o ejecutando:

```bash
packettracer
```

## Instalación mediante ClusterSSH (`cssh`)

ClusterSSH permite abrir sesiones SSH en varios equipos simultáneamente y enviar comandos a todos ellos desde una consola de control.

Este método resulta útil para desplegar Packet Tracer en varios equipos de un centro educativo.

### 1. Requisitos previos

Antes de comenzar, comprueba que:

- ClusterSSH (`cssh`) está instalado en el equipo desde el que se realizará el despliegue.
- Los equipos de destino tienen SSH habilitado y son accesibles por red.
- Dispones de una cuenta con permisos de `sudo` en cada equipo.
- La autenticación SSH funciona correctamente.
- Los equipos tienen acceso a Internet.

### 2. Abrir las sesiones SSH

Para conectarte a varios equipos, ejecuta:

```bash
cssh usuario@equipo01 usuario@equipo02 usuario@equipo03
```

Sustituye `usuario` y los nombres de los equipos por los valores correspondientes a tu entorno.

También puedes utilizar sus direcciones IP:

```bash
cssh usuario@192.168.1.101 usuario@192.168.1.102 usuario@192.168.1.103
```

ClusterSSH abrirá una terminal para cada equipo y una consola de control desde la que podrás enviar comandos a todas las sesiones simultáneamente.

### 3. Ejecutar la instalación en todos los equipos

Una vez conectadas las sesiones, introduce los siguientes comandos en la consola de control de ClusterSSH:

```bash
curl -o setup.sh https://raw.githubusercontent.com/pauchiner/packet-tracer/refs/heads/main/setup.sh
chmod +x setup.sh
./setup.sh
```

Los comandos se enviarán a las sesiones seleccionadas.

**Importante:** el instalador es interactivo cuando solicita la contraseña de `sudo`. Si cada equipo requiere autenticación independiente, deberás gestionar esas solicitudes en las terminales correspondientes. Para despliegues numerosos, es preferible configurar previamente la autenticación SSH mediante claves y una política de `sudo` adecuada.

### 4. Comprobar la instalación

Puedes comprobar que Packet Tracer está instalado en cada equipo ejecutando:

```bash
dpkg-query -W -f='${Status}\n' packettracer
```

El resultado esperado es:

```text
install ok installed
```

También puedes comprobar la disponibilidad del ejecutable:

```bash
command -v packettracer
```

### 5. Recomendaciones para despliegues masivos

- Prueba primero la instalación en un único equipo.
- Comprueba que el paquete funciona correctamente antes de desplegarlo en toda el aula.
- Verifica que las credenciales y los permisos de `sudo` funcionan en todos los equipos.
- No envíes comandos destructivos ni cambios de configuración a todos los equipos sin comprobar previamente el alcance de la operación.
- Si se interrumpe una instalación, comprueba el estado de APT y revisa si queda algún repositorio temporal habilitado.

## Repositorios de Ubuntu Jammy

LliureX utiliza su propia configuración de repositorios. Para facilitar la instalación de Packet Tracer, el script habilita temporalmente los repositorios de Ubuntu Jammy.

Durante el proceso:

1. Se crea un fichero independiente para los repositorios temporales.
2. Se actualizan los índices de APT.
3. Se instala Packet Tracer y se resuelven sus dependencias.
4. Al finalizar, se elimina el fichero temporal y se vuelven a actualizar los índices.

El instalador evita modificar directamente el fichero principal de repositorios de LliureX.

Ten en cuenta que la compatibilidad de paquetes de Ubuntu Jammy depende de la versión concreta de LliureX. La retirada de los repositorios temporales no revierte los paquetes que se hayan instalado.

## Archivos y ubicaciones

| Elemento | Ubicación |
|---|---|
| Script de instalación | `setup.sh` |
| Paquete descargado | `~/packettracer-install/CiscoPacketTracer_900_Ubuntu_64bit.deb` |
| Icono | `/opt/pt/art/app.png` |
| Acceso directo | `/usr/share/applications/packettracer.desktop` |
| Repositorios temporales | `/etc/apt/sources.list.d/packettracer-jammy-temp.list` |

## Solución de problemas

### Error al descargar Packet Tracer

Comprueba la conexión a Internet y que la URL de descarga siga disponible.

### Error al resolver dependencias

Revisa los mensajes de APT y comprueba la compatibilidad de los paquetes con la versión de LliureX instalada.

### No aparece el acceso directo

Comprueba que existe el fichero:

```bash
ls -l /usr/share/applications/packettracer.desktop
```

### El instalador se ha interrumpido

Comprueba si ha quedado el fichero temporal de repositorios:

```bash
ls -l /etc/apt/sources.list.d/packettracer-jammy-temp.list
```

Si existe, verifica que pertenece a esta instalación antes de retirarlo. No elimines configuraciones de repositorios que hayan sido creadas o utilizadas por otros procesos.
